import Foundation

/// Ejecuta comandos remotos por SSH usando conexiones ssh/sftp del vault, con
/// la misma política de modos que db_query (details.mode):
///   lectura → solo comandos de lectura (ls, cat, df, ps…).
///   info    → bloquea escritura y muestra el comando para consola.
///   edicion → permite comandos moderados con confirm=true; bloquea destructivos.
///   unsafe  → permite todo con confirm=true.
/// Clasificación por listas: destructivos (rm, dd, chmod, kill, >, …) y de
/// lectura (allowlist); todo lo demás es moderado.
final class SshRunner {
    struct Result {
        let ok: Bool
        let message: String
    }

    private let store = Store.shared
    private let resolver = DbTunnel()

    func exec(sshName: String, command: String, confirm: Bool, timeout: Int) -> Result {
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
        let tier = Self.classify(command)
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
        if tier != .read {
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

        // Guardas de datos completos: llave SSH o password.
        guard !host.isEmpty, !user.isEmpty else {
            return Result(ok: false, message: "La conexión '\(connName)' no tiene host o usuario guardado")
        }
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

        // Las lecturas sensibles usan su propia ventana; escrituras siempre frescas.
        let granted: Bool
        if let sensitiveFile, tier == .read {
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

    // MARK: - Clasificación

    enum SshTier { case read, moderate, destructive }

    /// Destructivos: patrones que borran, sobreescriben el sistema, cambian
    /// permisos, matan procesos o instalan. Se buscan en TODO el comando
    /// (cubre cadenas con &&, ;, |). La escritura de archivos (>, >>, tee,
    /// sed -i) es MODERADA: permite flujos de investigación con logs en modo
    /// edición. Lectura: allowlist de comandos seguros. Resto: moderado.
    static func classify(_ command: String) -> SshTier {
        let lower = command.lowercased()
        let destructive = [
            "rm ", "rm -", "rmdir", "shred", "dd ", "mkfs", "shutdown", "reboot",
            "halt", "poweroff", "init 0", "init 6", "kill ", "killall", "pkill",
            "userdel", "groupdel", "passwd", "visudo", "fdisk", "parted",
            "truncate ", "chown", "chmod", "chgrp", "mv ", "perl -i",
            "apt ", "apt-get", "yum ", "dnf ", "pacman -",
            "systemctl", "service ", "crontab", "scp ", "rsync", "wget ",
            "curl ", "pip ", "npm ", "composer ", "git push", "git reset",
            "git clean", "find /", "-delete", "-exec ",
        ]
        if destructive.contains(where: lower.contains) { return .destructive }

        let first = lower.split(separator: " ").first.map(String.init) ?? ""
        let readAllow: Set<String> = [
            "ls", "cat", "head", "tail", "grep", "find", "df", "du", "free",
            "uptime", "who", "w", "ps", "uname", "hostname", "date", "echo",
            "pwd", "env", "printenv", "stat", "file", "wc", "sort", "uniq",
            "md5sum", "sha256sum", "which", "id", "groups", "last", "history",
            "netstat", "ss", "ifconfig", "ip", "ping", "dig", "nslookup",
            "crontab", "git", "tar", "mysql", "psql", "php", "node", "python",
            "python3", "composer", "artisan", "wp",
        ]
        // Comandos de lectura con subcomandos/flags de escritura conocidos.
        if first == "git" {
            let sub = lower.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            return ["status", "log", "diff", "branch", "show", "remote", "tag"].contains(sub) ? .read : .moderate
        }
        if first == "tar" {
            return lower.contains("-t") || lower.contains("--list") ? .read : .moderate
        }
        if first == "crontab" {
            return lower.contains("-l") ? .read : .moderate
        }
        return readAllow.contains(first) ? .read : .moderate
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
