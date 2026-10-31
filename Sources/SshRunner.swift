import Foundation

/// Ejecuta comandos remotos por SSH. Los comandos fuera de la allowlist acotada
/// son ejecución nativa y requieren modo unsafe y Touch ID fresco.
final class SshRunner {
    struct Result {
        let ok: Bool
        let message: String
    }

    private let store = Store.shared
    private let resolver = DbTunnel()

    func exec(sshName: String, command: String, confirm: Bool, timeout: Int,
              nativeExecution: Bool = false) -> Result {
        let resolve = resolver.resolveConnection(name: sshName, protocols: DbTunnel.tunnelProtocols)
        guard case .found(let conn) = resolve else {
            switch resolve {
            case .notFound(let tried):
                return Result(ok: false, message: "No existe una conexión ssh/sftp llamada '\(sshName)'. \(tried)")
            case .ambiguous(let candidates):
                return Result(ok: false, message: "Varias conexiones coinciden con '\(sshName)': \(candidates). Sé más específico.")
            default: break
            }
            return Result(ok: false, message: "Conexión no encontrada")
        }
        let connName = conn["name"] as? String ?? sshName
        let details = store.detailsDict(from: conn)
        let host = conn["host"] as? String ?? ""
        let user = conn["username"] as? String ?? ""
        let port = conn["port"] as? Int ?? 22

        // Política según el modo — ANTES de tocar el Keychain (fail fast).
        let modeRaw = (details["mode"] ?? "lectura").lowercased()
        let mode = modeRaw == "safe" ? "lectura" : modeRaw
        let tier = nativeExecution ? SSHCommandTier.native : SSHCommandPolicy.classify(command)
        if let privateKeyFile = SensitiveFilePolicy.matchedPrivateKeyName(in: command) {
            return Result(
                ok: false,
                message: "🔒 Acceso bloqueado: el contenido de llaves privadas nunca se devuelve al chat ('\(privateKeyFile)').")
        }
        let sensitiveFile = SensitiveFilePolicy.matchedName(in: command)
        if let sensitiveFile {
            guard SensitiveFilePolicy.isEnabled(in: details) else {
                return Result(ok: false, message: """
                🔒 Acceso bloqueado: el comando menciona el archivo protegido '\(sensitiveFile)'.
                Activa «Permitir lectura de archivos sensibles» en esta conexión SSH para autorizar excepciones.
                """)
            }
            guard confirm else {
                return Result(ok: false, message: """
                ⚠️ ARCHIVO SENSIBLE — el comando puede acceder a '\(sensitiveFile)' en '\(connName)'.
                Repite la llamada con confirm=true. El primer acceso pide Touch ID; las lecturas aprobadas se reutilizan durante 15 min para esta conexión.

                Comando:
                \(command)
                """)
            }
        }
        let hostHint = host.isEmpty ? "(host)" : host
        let userHint = user.isEmpty ? "(usuario)" : user
        guard !host.isEmpty, !user.isEmpty else {
            return Result(ok: false, message: "La conexión '\(connName)' no tiene host o usuario guardado")
        }
        var nativeAuthorized = false
        if tier == .native {
            guard SSHCommandPolicy.allowsNativeExecution(mode: mode) else {
                let guidance = mode == "info"
                    ? "El modo info no ejecuta código nativo."
                    : "Cambia esta conexión a modo unsafe para permitirlo."
                return Result(ok: false, message: """
                🔒 Ejecución nativa bloqueada en modo '\(mode)'. \(guidance)
                Un proceso nativo puede acceder a los archivos y datos disponibles para esta cuenta SSH.

                Destino: \(userHint)@\(hostHint):\(port)
                Comando:
                \(command)
                """)
            }
            nativeAuthorized = AuthSession.shared.forceAuthorize(
                reason: "GDW Vault: ejecutar código nativo por SSH en \(connName), \(userHint)@\(hostHint):\(port). El proceso tendrá los permisos de esa cuenta."
            )
            guard nativeAuthorized else {
                return Result(ok: false, message: "Touch ID rechazado para ejecución nativa")
            }
        } else if tier != .read {
            switch mode {
            case "edicion":
                if tier == .destructive {
                    return Result(ok: false, message: """
                    🔒 Modo 'edición': permite comandos moderados pero no destructivos (rm, dd, chmod, kill, …). Ejecútalo tú en consola:

                    ssh -p \(port) \(userHint)@\(hostHint) '<command>'

                    Comando:
                    \(command)
                    """)
                }
                guard confirm else {
                    return Result(ok: false, message: """
                    ⚠️ MODO EDICIÓN — el comando modifica el servidor '\(connName)'.
                    Para ejecutarlo, repite la llamada con confirm=true y aprueba el Touch ID.

                    Comando:
                    \(command)
                    """)
                }
            case "unsafe":
                guard confirm else {
                    return Result(ok: false, message: """
                    ⚠️ MODO UNSAFE — el comando modifica el servidor '\(connName)'.
                    Para ejecutarlo, repite la llamada con confirm=true y aprueba el Touch ID.

                    Comando:
                    \(command)
                    """)
                }
            case "info":
                return Result(ok: false, message: """
                🔒 Modo 'info': no ejecuto comandos de escritura. Ejecútalo tú en consola:

                ssh -p \(port) \(userHint)@\(hostHint) '<command>'

                Comando:
                \(command)
                """)
            default:
                return Result(ok: false, message: "🔒 Modo 'lectura': solo comandos de lectura (ls, cat, df, ps, grep…). Cambia la conexión '\(connName)' a modo 'info', 'edición' o 'unsafe' en el formulario si lo necesitas.")
            }
        }

        // Guarda de credenciales: llave SSH o password.
        // Autenticación por llave si la conexión tiene una asignada.
        var keyPath: String?
        if let keyId = conn["key_id"] as? Int,
           let key = store.findKey(id: keyId),
           let path = key["secret_path"] as? String,
           FileManager.default.isReadableFile(atPath: path) {
            keyPath = path
        }
        var secret: String?
        if keyPath == nil {
            secret = store.secretFor(connection: conn)
            guard let secret, !secret.isEmpty else {
                return Result(ok: false, message: "La conexión '\(connName)' no tiene llave asignada ni password guardado")
            }
            AuthSession.shared.markSecretUsed(account: conn["keychain_account"] as? String ?? "")
        }

        // La ejecución nativa ya exigió consentimiento y Touch ID frescos antes
        // de consultar el Keychain; no se reutiliza esa autorización.
        let granted: Bool
        if nativeAuthorized {
            granted = true
        } else if let sensitiveFile, tier == .read {
            granted = AuthSession.shared.authorizeSensitiveRead(
                account: conn["keychain_account"] as? String ?? "",
                reason: "GDW Vault: leer el archivo sensible \"\(sensitiveFile)\" de \"\(connName)\"."
            )
        } else if tier == .read {
            granted = AuthSession.shared.authorize(
                reason: "GDW Vault: ejecutar comando de lectura en \"\(connName)\"."
            )
        } else {
            granted = AuthSession.shared.forceAuthorize(
                reason: "GDW Vault: ejecutar comando de ESCRITURA en \"\(connName)\" (modo \(mode))."
            )
        }
        guard granted else {
            return Result(ok: false, message: "Touch ID rechazado")
        }

        // Ejecución: por llave (directo, BatchMode) o por password (expect).
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let outFile = outDir.appendingPathComponent("gdw-ssh-out-\(UUID().uuidString)")
        let process: Process?
        if let keyPath {
            process = Self.spawnSshKeyCommand(host: host, port: port, user: user,
                                              keyPath: keyPath, command: command,
                                              timeout: timeout, outFile: outFile)
        } else {
            process = Self.spawnSshCommand(host: host, port: port, user: user,
                                           password: secret ?? "", command: command,
                                           timeout: timeout, outFile: outFile)
        }
        guard let process else {
            return Result(ok: false, message: "No se pudo iniciar el comando SSH")
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        let output = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: outFile)

        if status == 2 {
            return Result(ok: false, message: "El comando excedió el timeout de \(timeout)s")
        }
        if status == 4 {
            return Result(ok: false, message: "Autenticación fallida (¿host, usuario o password incorrectos?)")
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if status != 0 {
            return Result(ok: false, message: "El comando terminó con código \(status):\n\(trimmed)")
        }
        return Result(ok: true, message: trimmed.isEmpty ? "(sin salida)" : trimmed)
    }

    // MARK: - Ejecución

    /// Lanza ssh directo con llave (BatchMode: sin prompt de password).
    private static func spawnSshKeyCommand(host: String, port: Int, user: String,
                                           keyPath: String, command: String,
                                           timeout: Int, outFile: URL) -> Process? {
        let sshPath = "/usr/bin/ssh"
        guard FileManager.default.isExecutableFile(atPath: sshPath) else { return nil }
        let limit = max(5, min(300, timeout))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = [
            "-i", keyPath,
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=\(limit)",
            "-p", String(port),
            "\(user)@\(host)", command,
        ]
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return nil
        }
        // Watchdog: cortar si el comando se cuelga más del timeout.
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + .init(limit)) == .timedOut {
            process.terminate()
        }
        process.waitUntilExit()
        var out = (outPipe.fileHandleForReading.readDataToEndOfFile())
        var err = (errPipe.fileHandleForReading.readDataToEndOfFile())
        var status = process.terminationStatus
        var lastProcess: Process?

        // Servidores viejos solo ofrecen host keys ssh-rsa: reintentar con
        // algoritmos legacy si el cliente los rechazó. Las opciones deben
        // insertarse ANTES del user@host (si no, ssh las pasa al comando remoto).
        let errText0 = String(data: err, encoding: .utf8) ?? ""
        if status != 0, errText0.contains("no matching host key type") {
            let legacy = Process()
            legacy.executableURL = URL(fileURLWithPath: sshPath)
            var legacyArgs = process.arguments ?? []
            if let idx = legacyArgs.firstIndex(where: { $0.contains("@") }) {
                legacyArgs.insert(contentsOf: [
                    "-o", "HostKeyAlgorithms=+ssh-rsa",
                    "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
                ], at: idx)
            }
            legacy.arguments = legacyArgs
            let out2 = Pipe(), err2 = Pipe()
            legacy.standardOutput = out2
            legacy.standardError = err2
            if (try? legacy.run()) != nil {
                let sem2 = DispatchSemaphore(value: 0)
                legacy.terminationHandler = { _ in sem2.signal() }
                if sem2.wait(timeout: .now() + .init(limit)) == .timedOut {
                    legacy.terminate()
                }
                legacy.waitUntilExit()
                out = out2.fileHandleForReading.readDataToEndOfFile()
                err = err2.fileHandleForReading.readDataToEndOfFile()
                status = legacy.terminationStatus
                lastProcess = legacy
            }
        }
        var text = String(data: out, encoding: .utf8) ?? ""
        let errText = String(data: err, encoding: .utf8) ?? ""
        if status != 0, !errText.isEmpty {
            text += "\n" + errText
        }
        try? text.write(to: outFile, atomically: true, encoding: .utf8)
        // Devolver el proceso del intento FINAL: exec() lee su terminationStatus.
        return lastProcess ?? process
    }

    /// Lanza ssh con expect; la salida del comando se captura en outFile
    /// (log_user 0 durante el login para no capturar el prompt del password).
    private static func spawnSshCommand(host: String, port: Int, user: String,
                                        password: String, command: String,
                                        timeout: Int, outFile: URL) -> Process? {
        let expectPath = "/usr/bin/expect"
        guard FileManager.default.isExecutableFile(atPath: expectPath) else { return nil }
        let passFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gdw-ssh-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: passFile.path, contents: Data(password.utf8),
                                       attributes: [.posixPermissions: 0o600])
        let sanitize: (String) -> String = { $0.filter { $0 != "{" && $0 != "}" } }
        // Las comillas simples SÍ se conservan: dentro de llaves Tcl son literales
        // seguras, y quitárselas a los comandos rompe `mysql -e '...'` etc.
        let script = """
        set timeout \(max(5, min(300, timeout)))
        log_user 0
        log_file -noappend {\(outFile.path)}
        set pass [exec cat {\(passFile.path)}]
        exec rm -f {\(passFile.path)}
        set pass [string trimright $pass "\\r\\n"]
        spawn /usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -p {\(port)} {\(sanitize(user))@\(sanitize(host))} {\(sanitize(command))}
        expect {
            -re "(?i)password.*:" { send -- "$pass\\r" }
            eof { exit 1 }
            timeout { exit 2 }
        }
        log_user 1
        expect {
            -re "(?i)password.*:" { exit 4 }
            eof {}
            timeout { exit 2 }
        }
        exit [lindex [wait] 3]
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
            try? FileManager.default.removeItem(at: outFile)
            return nil
        }
        return process
    }
}
