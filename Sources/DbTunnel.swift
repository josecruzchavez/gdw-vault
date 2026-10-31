import Foundation

/// Consulta una base de datos MySQL/MariaDB usando las conexiones del vault.
/// - Si el host de la BD es local y hay una conexión ssh/sftp en el mismo grupo,
///   abre un túnel por ella; si no hay ssh, conecta directo (BD en esta Mac).
/// - Política de escritura por conexión (details.mode):
///   lectura → solo SELECT/SHOW (legacy "safe").
///   info    → bloquea escritura y muestra cómo ejecutarla en consola.
///   edicion → permite INSERT/UPDATE con confirm=true; bloquea destructivas.
///   unsafe  → permite todo con confirm=true.
/// Los secretos nunca salen del proceso (se pasan por stdin/expect).
final class DbTunnel {
    struct Result {
        let ok: Bool
        let message: String
    }

    private let store = Store.shared
    private var note: String?

    enum Resolve {
        case found([String: Any])
        case notFound(String)
        case ambiguous([String])
    }

    /// Resuelve un nombre de conexión: exacta (sin distinguir mayúsculas), parcial
    /// en ambos sentidos y por último difusa (typos vía distancia Levenshtein).
    /// Devuelve el registro completo (con keychain_account).
    func resolveConnection(name: String, protocols: Set<String>) -> Resolve {
        let candidates = store.listConnections().filter { protocols.contains($0["protocol"] as? String ?? "") }
        let lower = name.lowercased()
        var matched: [String: Any]?
        if let exact = candidates.first(where: { ($0["name"] as? String)?.lowercased() == lower }) {
            matched = exact
        } else {
            let partial = candidates.filter {
                guard let n = $0["name"] as? String else { return false }
                return n.lowercased().contains(lower) || lower.contains(n.lowercased())
            }
            if partial.count == 1 { matched = partial.first }
            if partial.count > 1 {
                return .ambiguous(partial.compactMap { $0["name"] as? String })
            }
            // Difusa SOLO si el parcial no encontró nada: tolerar typos
            // ("loclahost" → "Localhost"); no sobrescribe un match parcial.
            if matched == nil {
                // Orden: distancia, luego que el nombre TERMINE con lo escrito
                // (el sufijo suele ser la parte distintiva: "…2026"), luego más corto.
                func rank(_ row: [String: Any]) -> (Int, Int, Int) {
                    let n = (row["name"] as? String ?? "").lowercased()
                    return (Self.levenshtein(lower, n),
                            n.hasSuffix(lower) ? 0 : 1,
                            -n.count)
                }
                let ranked = candidates
                    .filter { rank($0).0 <= Self.fuzzyThreshold(lower) }
                    .sorted { rank($0) < rank($1) }
                if ranked.count == 1 { matched = ranked[0] }
                if ranked.count > 1 {
                    // Ganador claro: estrictamente mejor que el segundo.
                    if rank(ranked[0]) < rank(ranked[1]) {
                        matched = ranked[0]
                    } else {
                        return .ambiguous(ranked.map { $0["name"] as? String ?? "?" })
                    }
                }
            }
        }
        guard let row = matched else {
            let available = candidates.compactMap { $0["name"] as? String }.prefix(8).joined(separator: ", ")
            return .notFound(available.isEmpty ? "No hay conexiones de ese tipo." : "Conexiones disponibles: \(available)…")
        }
        return .found(store.findConnection(id: row["id"] as? Int) ?? row)
    }

    /// Tolerancia de typos proporcional al largo (1 para cortos, hasta 3).
    private static func fuzzyThreshold(_ s: String) -> Int {
        max(1, min(3, s.count / 3))
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[t.count]
    }

    /// Ejecuta una consulta SQL. Detecta el túnel automáticamente y aplica la
    /// política de escritura del modo de la conexión (safe/info/unsafe).
    func query(sshName: String?, dbName: String, sql: String, database: String?, confirm: Bool) -> Result {
        // 1. Resolver la conexión de BD (exacta, luego parcial).
        let dbResolve = resolveConnection(name: dbName, protocols: Self.dbProtocols)
        guard case .found(let dbConn) = dbResolve else {
            switch dbResolve {
            case .notFound(let tried):
                return Result(ok: false, message: "No existe una conexión mysql llamada '\(dbName)' (usa list_connections). \(tried)")
            case .ambiguous(let candidates):
                return Result(ok: false, message: "Varias conexiones coinciden con '\(dbName)': \(candidates). Sé más específico.")
            default: break
            }
            return Result(ok: false, message: "Conexión no encontrada")
        }
        let connName = dbConn["name"] as? String ?? dbName
        let details = store.detailsDict(from: dbConn)
        let dbHost = dbConn["host"] as? String ?? ""
        let dbUser = dbConn["username"] as? String ?? ""
        let dbProto = dbConn["protocol"] as? String ?? "mysql"
        let isPostgres = dbProto == "postgres"
        let dbPort = dbConn["port"] as? Int ?? (isPostgres ? 5432 : 3306)
        let schema = (database?.isEmpty == false ? database : details["database"]) ?? ""

        // 2. Política de escritura según el modo de la conexión — ANTES de
        //    tocar el Keychain: fallar rápido no lee secretos ni pide Touch ID.
        //    Modos: lectura | info | edicion | unsafe (legacy "safe" = lectura).
        let modeRaw = (details["mode"] ?? "lectura").lowercased()
        let mode = modeRaw == "safe" ? "lectura" : modeRaw
        let tier = Self.tier(sql)
        let clientName = isPostgres ? "psql" : "mysql"
        let hostHint = dbHost.isEmpty ? "(host)" : dbHost
        let userHint = dbUser.isEmpty ? "(usuario)" : dbUser
        let schemaHint = schema.isEmpty ? "(base)" : schema
        if tier != .read {
            switch mode {
            case "edicion":
                if tier == .destructive {
                    return Result(ok: false, message: """
                    🔒 Modo 'edición': permite INSERT/UPDATE pero no DELETE/DROP/TRUNCATE/ALTER. Ejecútalo tú en consola:

                    \(clientName) -h \(hostHint) -p \(dbPort) -\(isPostgres ? "U" : "u") \(userHint) \(schemaHint) -c "<sql>"

                    SQL:
                    \(sql)
                    """)
                }
                guard confirm else {
                    return Result(ok: false, message: """
                    ⚠️ MODO EDICIÓN — el SQL modifica datos en '\(connName)'.
                    Para ejecutarlo, repite la llamada con confirm=true y aprueba el Touch ID.

                    SQL:
                    \(sql)
                    """)
                }
            case "unsafe":
                guard confirm else {
                    return Result(ok: false, message: """
                    ⚠️ MODO UNSAFE — el SQL modifica datos o estructura en '\(connName)'.
                    Para ejecutarlo, repite la llamada con confirm=true y aprueba el Touch ID.

                    SQL:
                    \(sql)
                    """)
                }
            case "info":
                return Result(ok: false, message: """
                🔒 Modo 'info': no ejecuto consultas de escritura. Ejecútalo tú en consola:

                \(clientName) -h \(hostHint) -p \(dbPort) -\(isPostgres ? "U" : "u") \(userHint) \(schemaHint) -c "<sql>"

                SQL:
                \(sql)
                """)
            default:
                return Result(ok: false, message: "🔒 Modo 'lectura': solo se permiten consultas de lectura (SELECT, SHOW, DESCRIBE, EXPLAIN). Cambia la conexión '\(connName)' a modo 'info', 'edición' o 'unsafe' en el formulario si lo necesitas.")
            }
        }

        // 3. Guardas de datos completos (requieren leer el Keychain).
        guard !dbHost.isEmpty, !dbUser.isEmpty,
              let dbSecret = store.secretFor(connection: dbConn), !dbSecret.isEmpty else {
            return Result(ok: false, message: "La conexión '\(connName)' no tiene host, usuario o password guardado")
        }
        AuthSession.shared.markSecretUsed(account: dbConn["keychain_account"] as? String ?? "")
        guard !schema.isEmpty else {
            return Result(ok: false, message: "No hay base de datos: pásala en 'database' o guárdala en la conexión")
        }

        // 3. Túnel: solo si el host es local Y hay ssh/sftp en el grupo (o ssh_name explícito).
        //    Sin ssh en el grupo, el localhost es esta Mac: conexión directa.
        let isLocal = Self.localHosts.contains(dbHost.lowercased())
        var sshConn: [String: Any]?
        if isLocal {
            if let sshName, !sshName.isEmpty {
                let sshResolve = resolveConnection(name: sshName, protocols: Self.tunnelProtocols)
                guard case .found(let conn) = sshResolve else {
                    switch sshResolve {
                    case .notFound(let tried):
                        return Result(ok: false, message: "No existe una conexión ssh/sftp llamada '\(sshName)'. \(tried)")
                    case .ambiguous(let candidates):
                        return Result(ok: false, message: "Varias conexiones ssh coinciden con '\(sshName)': \(candidates). Sé más específico.")
                    default: break
                    }
                    return Result(ok: false, message: "Conexión ssh no encontrada")
                }
                sshConn = conn
            } else {
                let candidates = store.listConnections().filter {
                    ($0["group_name"] as? String) == (dbConn["group_name"] as? String)
                        && Self.tunnelProtocols.contains($0["protocol"] as? String ?? "")
                }
                if let first = candidates.first {
                    // Registro completo (listConnections no trae keychain_account).
                    sshConn = store.findConnection(id: first["id"] as? Int) ?? first
                    if candidates.count > 1 {
                        let names = candidates.compactMap { $0["name"] as? String }.joined(separator: ", ")
                        note = "Túnel por '\(first["name"] as? String ?? "?")' (también hay: \(names))."
                    }
                }
            }
        }

        var sshHost = "", sshUser = "", sshSecret = ""
        var sshPort = 22
        if let sshConn {
            guard let host = sshConn["host"] as? String, !host.isEmpty,
                  let user = sshConn["username"] as? String, !user.isEmpty,
                  let secret = store.secretFor(connection: sshConn), !secret.isEmpty else {
                return Result(ok: false, message: "La conexión '\(sshConn["name"] as? String ?? "?")' no tiene host, usuario o password guardado")
            }
            sshHost = host
            sshUser = user
            sshSecret = secret
            sshPort = sshConn["port"] as? Int ?? 22
        }

        // Touch ID según el tipo de consulta:
        // - Solo lectura: ventana de gracia (15 min), no repite prompt.
        // - Escritura permitida (edición/unsafe + confirm): Touch ID fresco siempre.
        let granted: Bool
        if tier != .read {
            granted = AuthSession.shared.forceAuthorize(
                reason: "GDW Vault: ejecutar SQL de escritura en \"\(connName)\" (modo \(mode))."
            )
        } else {
            granted = AuthSession.shared.authorize(
                reason: "GDW Vault: usar los accesos guardados para ejecutar SQL en \"\(connName)\"."
            )
        }
        guard granted else {
            return Result(ok: false, message: "Touch ID rechazado")
        }

        var localPort: Int?
        var tunnelProcess: Process?
        if sshConn != nil {
            // 4. Túnel SSH: puerto local efímero -> localhost:dbPort en el servidor.
            localPort = Self.freePort()
            guard let localPort else {
                return Result(ok: false, message: "No se pudo encontrar un puerto local libre")
            }
            let sshArgs = [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PreferredAuthentications=password",
                "-o", "PubkeyAuthentication=no",
                "-p", String(sshPort),
                "-N", "-L", "\(localPort):localhost:\(dbPort)",
                "\(sshUser)@\(sshHost)",
            ]
            guard let tunnel = Self.spawnSsh(args: sshArgs, password: sshSecret) else {
                return Result(ok: false, message: "No se pudo iniciar el túnel SSH")
            }
            tunnelProcess = tunnel
            guard Self.waitPort(localPort, timeout: 20) else {
                tunnel.terminate()
                return Result(ok: false, message: "El túnel SSH no se estableció (¿host, usuario o password incorrectos?)")
            }
        }

        // 5. Consulta: directo al host o por el túnel, con el cliente correspondiente.
        let clientPath: String
        if isPostgres {
            clientPath = Self.findPsqlClient() ?? "/usr/bin/psql"
        } else {
            clientPath = Self.findMysqlClient() ?? "/usr/bin/mysql"
        }
        let client = Process()
        client.executableURL = URL(fileURLWithPath: clientPath)
        if isPostgres {
            client.arguments = [
                "-h", localPort == nil ? dbHost : "127.0.0.1",
                "-p", String(localPort ?? dbPort),
                "-U", dbUser, "-d", schema,
                "-v", "ON_ERROR_STOP=1", "-c", sql,
            ]
            var env = ProcessInfo.processInfo.environment
            env["PGPASSWORD"] = dbSecret
            env["PGCONNECT_TIMEOUT"] = "10"
            client.environment = env
        } else {
            client.arguments = [
                "-h", localPort == nil ? dbHost : "127.0.0.1",
                "-P", String(localPort ?? dbPort),
                "-u", dbUser, "-p\(dbSecret)",
                "--connect-timeout=10", schema, "-e", sql,
            ]
        }
        let outPipe = Pipe(), errPipe = Pipe()
        client.standardOutput = outPipe
        client.standardError = errPipe
        do {
            try client.run()
        } catch {
            tunnelProcess?.terminate()
            return Result(ok: false, message: "No se pudo ejecutar el cliente de base de datos (\(clientPath)): \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        client.waitUntilExit()
        let status = client.terminationStatus
        tunnelProcess?.terminate()

        if status != 0 {
            let err = String(data: errData, encoding: .utf8) ?? ""
            return Result(ok: false, message: "Error SQL: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        var output = String(data: outData, encoding: .utf8) ?? ""
        if output.isEmpty { output = "(sin filas)" }
        if let note { output = note + "\n" + output }
        return Result(ok: true, message: output)
    }

    /// Cierra el túnel persistente, si lo hay. (Reservado: db_query ahora es
    /// stateless, el túnel vive solo dentro de query().)
    func closeTunnel() {}

    // MARK: - Helpers

    /// Protocolos que pueden actuar como puente SSH (túneles y ejecución remota).
    static let tunnelProtocols: Set<String> = ["ssh", "sftp"]
    private static let dbProtocols: Set<String> = ["mysql", "postgres"]
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Nivel de riesgo de una sentencia SQL.
    enum SqlTier { case read, insert, update, destructive }

    /// Clasifica el SQL completo (varias sentencias separadas por ';') por el
    /// nivel MÁS ALTO que contenga. Formas de escritura encubierta
    /// (INTO OUTFILE, LOAD DATA) cuentan como destructivas.
    static func tier(_ sql: String) -> SqlTier {
        let order: [SqlTier: Int] = [.read: 0, .insert: 1, .update: 2, .destructive: 3]
        let statements = sql
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !statements.isEmpty else { return .destructive }
        var highest = SqlTier.read
        for statement in statements {
            // Quitar líneas de comentario para ver el comando real.
            let code = statement
                .components(separatedBy: .newlines)
                .filter { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return !t.hasPrefix("--") && !t.hasPrefix("#") && !t.hasPrefix("/*")
                }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let lower = code.lowercased()
            let tierStatement: SqlTier
            if ["into outfile", "into dumpfile", "load data", "load_file", "handler"].contains(where: lower.contains) {
                tierStatement = .destructive
            } else {
                switch lower.split(separator: " ").first.map(String.init) {
                case "select", "show", "describe", "desc", "explain", "with": tierStatement = .read
                case "insert", "replace": tierStatement = .insert
                case "update": tierStatement = .update
                default: tierStatement = .destructive
                }
            }
            if order[tierStatement]! > order[highest]! { highest = tierStatement }
        }
        return highest
    }

    /// Lanza ssh con expect para responder el prompt de password sin exponerlo en argv.
    private static func spawnSsh(args: [String], password: String) -> Process? {
        let expectPath = "/usr/bin/expect"
        guard FileManager.default.isExecutableFile(atPath: expectPath) else { return nil }
        // El password va en un archivo temporal 0600 que expect lee; nunca en argv ni en el script.
        let passFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gdw-ssh-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: passFile.path, contents: Data(password.utf8),
                                       attributes: [.posixPermissions: 0o600])
        // expect borra el archivo tras leerlo; si falla el arranque, el catch de abajo lo limpia.
        let script = """
        set timeout 30
        set pass [exec cat {\(passFile.path)}]
        exec rm -f {\(passFile.path)}
        set pass [string trimright $pass "\\r\\n"]
        spawn /usr/bin/ssh \(args.map { arg -> String in
            // Tcl agrupa palabras con llaves; se eliminan para no romper el agrupado.
            let safe = arg.filter { $0 != "{" && $0 != "}" && $0 != "'" }
            return "{\(safe)}"
        }.joined(separator: " "))
        expect {
            -re "(?i)password.*:" { send -- "$pass\\r" }
            eof { exit 1 }
            timeout { exit 2 }
        }
        expect {
            eof { exit 3 }
            timeout { exit 0 }
        }
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: expectPath)
        process.arguments = ["-c", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: passFile)
            return nil
        }
        return process
    }

    private static func waitPort(_ port: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if portOpen(port) { return true }
            usleep(300_000)
        }
        return false
    }

    private static func portOpen(_ port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func freePort() -> Int? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard bind(fd, withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, len) == 0 else { return nil }
        getsockname(fd, withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &len)
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func findMysqlClient() -> String? {
        let candidates = [
            "/usr/local/mysql/bin/mysql",
            "/opt/homebrew/bin/mysql",
            "/usr/local/bin/mysql",
            "/usr/bin/mysql",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func findPsqlClient() -> String? {
        let candidates = [
            "/opt/homebrew/bin/psql",
            "/usr/local/bin/psql",
            "/usr/bin/psql",
            "/Applications/Postgres.app/Contents/Versions/latest/bin/psql",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
