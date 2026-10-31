import Foundation

/// Entrega el secreto de una conexión a un proceso local (CLI) sin que el
/// valor pase por el chat: viaja por variable de entorno o stdin y nunca
/// aparece en los argumentos del comando. MCP descarta stdout y stderr.
///
/// Procesa secretos locales con la política de modos de la conexión. Los
/// procesos nativos son código arbitrario y requieren modo unsafe y Touch ID fresco.
final class SecretBroker {
    struct Result {
        let ok: Bool
        let message: String
    }

    static let protocols: Set<String> = Set(ConnectionForm.protocols)
    static let defaultEnvVar = "GDW_SECRET"
    static let defaultTimeout = 60

    private let store = Store.shared
    private let resolver = DbTunnel()

    /// Ejecuta `command` con el secreto inyectado. `operatorOverride` lo usa
    /// la CLI: ahí el humano está operando, así que el modo no bloquea.
    func run(connectionName: String, command: String, envVar: String? = nil,
             viaStdin: Bool = false, confirm: Bool = false,
             timeout: Int = defaultTimeout, operatorOverride: Bool = false) -> Result {
        let resolve = resolver.resolveConnection(name: connectionName, protocols: Self.protocols)
        guard case .found(let conn) = resolve else {
            switch resolve {
            case .notFound(let tried):
                return Result(ok: false, message: "No existe una conexión llamada '\(connectionName)'. \(tried)")
            case .ambiguous(let candidates):
                return Result(ok: false, message: "Varias conexiones coinciden con '\(connectionName)': \(candidates). Sé más específico.")
            default:
                return Result(ok: false, message: "Conexión no encontrada")
            }
        }
        let connName = conn["name"] as? String ?? connectionName
        let details = store.detailsDict(from: conn)
        let modeRaw = (details["mode"] ?? "lectura").lowercased()
        let mode = modeRaw == "safe" ? "lectura" : modeRaw
        let tier = SSHCommandPolicy.classify(command)
        let protocolType = conn["protocol"] as? String ?? ""
        if let privateKeyFile = SensitiveFilePolicy.matchedPrivateKeyName(in: command) {
            return Result(
                ok: false,
                message: "🔒 Acceso bloqueado: el contenido de llaves privadas nunca se devuelve al chat ('\(privateKeyFile)').")
        }
        let sensitiveFile = ["ssh", "sftp"].contains(protocolType)
            ? SensitiveFilePolicy.matchedName(in: command) : nil
        let console = Self.consoleCommand(name: connName, command: command, envVar: envVar ?? Self.defaultEnvVar)
        var nativeAuthorized = false

        if let sensitiveFile {
            guard SensitiveFilePolicy.isEnabled(in: details) else {
                return Result(ok: false, message: """
                🔒 Operación bloqueada: el comando menciona el archivo protegido '\(sensitiveFile)'.
                Activa «Permitir lectura de archivos sensibles» en esta conexión SSH para autorizar excepciones.
                """)
            }
            guard confirm else {
                return Result(ok: false, message: """
                ⚠️ ARCHIVO SENSIBLE — el comando menciona '\(sensitiveFile)' usando la conexión '\(connName)'.
                Repite la llamada con confirm=true. El primer acceso pide Touch ID; las lecturas aprobadas se reutilizan durante 15 min para esta conexión.

                Comando:
                \(command)
                """)
            }
        }

        if !operatorOverride && tier == .native {
            guard SSHCommandPolicy.allowsNativeExecution(mode: mode) else {
                return Result(ok: false, message: """
                🔒 Ejecución nativa bloqueada en modo '\(mode)'. Cambia esta conexión a modo unsafe para permitirla.
                El proceso local se ejecutaría con los permisos de esta Mac y recibiría el secreto de «\(connName)».

                Comando:
                \(command)
                """)
            }
            let delivery = viaStdin ? "El proceso recibirá el secreto por stdin."
                : "El proceso recibirá el secreto en la variable \(envVar ?? Self.defaultEnvVar)."
            nativeAuthorized = AuthSession.shared.forceAuthorize(
                reason: "GDW Vault: ejecutar código nativo local con el secreto de \"\(connName)\". \(delivery)"
            )
            guard nativeAuthorized else {
                return Result(ok: false, message: "Touch ID rechazado para ejecución nativa")
            }
        }

        if !operatorOverride && tier != .read && tier != .native {
            switch mode {
            case "edicion":
                if tier == .destructive {
                    return Result(ok: false, message: """
                    🔒 Modo 'edición': permite comandos moderados pero no destructivos (rm, dd, chmod, kill, …). Ejecútalo tú en consola:

                    \(console)
                    """)
                }
                guard confirm else {
                    return Result(ok: false, message: """
                    ⚠️ MODO EDICIÓN — el comando se ejecuta en esta Mac con el secreto de '\(connName)'.
                    Para ejecutarlo, repite la llamada con confirm=true y aprueba el Touch ID.

                    Comando:
                    \(command)
                    """)
                }
            case "unsafe":
                guard confirm else {
                    return Result(ok: false, message: """
                    ⚠️ MODO UNSAFE — el comando se ejecuta en esta Mac con el secreto de '\(connName)'.
                    Para ejecutarlo, repite la llamada con confirm=true y aprueba el Touch ID.

                    Comando:
                    \(command)
                    """)
                }
            case "info":
                return Result(ok: false, message: """
                🔒 Modo 'info': no ejecuto comandos de escritura. Ejecútalo tú en consola:

                \(console)
                """)
            default:
                return Result(ok: false, message: "🔒 Modo 'lectura': solo comandos de lectura (ls, cat, df, ps, grep…). Cambia la conexión '\(connName)' a modo 'info', 'edición' o 'unsafe' si lo necesitas.")
            }
        }

        // El secreto puede ser un password o la ruta de una llave privada.
        var secret: String?
        var secretsToRedact: [String] = []
        if let account = conn["keychain_account"] as? String,
           let stored = KeychainStore.shared.getSecret(account: account), !stored.isEmpty {
            secret = stored
            secretsToRedact.append(stored)
        } else if let keyId = conn["key_id"] as? Int,
                  let key = store.findKey(id: keyId),
                  let path = key["secret_path"] as? String,
                  FileManager.default.isReadableFile(atPath: path) {
            secret = path
        }
        guard let secret else {
            return Result(ok: false, message: "La conexión '\(connName)' no tiene password ni llave guardados: no hay nada que inyectar.")
        }

        // Las lecturas sensibles usan su propia ventana; escrituras siempre frescas.
        let granted: Bool
        if nativeAuthorized {
            granted = true
        } else if let sensitiveFile {
            if tier == .read {
                granted = AuthSession.shared.authorizeSensitiveRead(
                    account: conn["keychain_account"] as? String ?? "",
                    reason: "GDW Vault: permitir acceso al archivo sensible \"\(sensitiveFile)\" usando \"\(connName)\"."
                )
            } else {
                granted = AuthSession.shared.forceAuthorize(
                    reason: "GDW Vault: permitir acceso al archivo sensible \"\(sensitiveFile)\" usando \"\(connName)\"."
                )
            }
        } else if tier == .read {
            granted = AuthSession.shared.authorize(
                reason: "GDW Vault: ejecutar comando local con el secreto de \"\(connName)\"."
            )
        } else if tier == .native {
            granted = AuthSession.shared.forceAuthorize(
                reason: "GDW Vault: ejecutar código nativo local con el secreto de \"\(connName)\"."
            )
        } else {
            granted = AuthSession.shared.forceAuthorize(
                reason: "GDW Vault: ejecutar comando de ESCRITURA en esta Mac con el secreto de \"\(connName)\" (modo \(mode))."
            )
        }
        guard granted else {
            return Result(ok: false, message: "Touch ID rechazado")
        }
        if let account = conn["keychain_account"] as? String, !account.isEmpty {
            AuthSession.shared.markSecretUsed(account: account)
        }

        let effectiveEnv = viaStdin ? nil : (envVar ?? Self.defaultEnvVar)
        if let effectiveEnv, !Self.isValidEnvName(effectiveEnv) {
            return Result(ok: false, message: "Nombre de variable inválido: '\(effectiveEnv)'. Usa letras, números y '_' (no puede empezar con número).")
        }

        let limit = max(5, min(300, timeout))
        let outputFile: URL?
        let outputHandle: FileHandle?
        if operatorOverride {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("gdw-exec-\(UUID().uuidString).log")
            FileManager.default.createFile(
                atPath: file.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
            guard let handle = try? FileHandle(forWritingTo: file) else {
                return Result(ok: false, message: "No se pudo preparar el archivo de salida")
            }
            outputFile = file
            outputHandle = handle
        } else {
            outputFile = nil
            outputHandle = nil
        }
        defer {
            try? outputHandle?.close()
            if let outputFile { try? FileManager.default.removeItem(at: outputFile) }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = outputHandle ?? FileHandle.nullDevice
        process.standardError = outputHandle ?? FileHandle.nullDevice

        var stdinPipe: Pipe?
        if viaStdin {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        var environment = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (environment["PATH"].map { "\(extraPath):\($0)" }) ?? extraPath
        environment.removeValue(forKey: Self.defaultEnvVar)
        if let effectiveEnv { environment[effectiveEnv] = secret }
        // La CLI también usa el broker; no debe arrastrar secretos del entorno.
        process.environment = environment

        do {
            try process.run()
        } catch {
            return Result(ok: false, message: "No se pudo iniciar el comando: \(error.localizedDescription)")
        }
        if let pipe = stdinPipe {
            pipe.fileHandleForWriting.write(Data((secret + "\n").utf8))
            try? pipe.fileHandleForWriting.close()
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + .seconds(limit)) == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return Result(ok: false, message: "El comando excedió el timeout de \(limit)s")
        }
        process.waitUntilExit()

        let status = process.terminationStatus
        guard operatorOverride else {
            return Result(
                ok: status == 0,
                message: "Comando terminado con código \(status). La salida se omitió porque el proceso tuvo acceso al secreto.")
        }

        let raw = outputFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let clean = OutputText.truncate(OutputText.redact(raw, secrets: secretsToRedact))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status != 0 {
            return Result(ok: false, message: "El comando terminó con código \(status):\n\(clean)")
        }
        var message = clean.isEmpty ? "(sin salida)" : clean
        if let effectiveEnv {
            message += "\n\n(el secreto se inyectó en $\(effectiveEnv); no aparece en la salida)"
        } else {
            message += "\n\n(el secreto se inyectó por stdin; no aparece en la salida)"
        }
        return Result(ok: true, message: message)
    }

    /// Comando equivalente para que el humano lo ejecute en su terminal.
    static func consoleCommand(name: String, command: String, envVar: String) -> String {
        let quotedName = name.replacingOccurrences(of: "\"", with: "\\\"")
        return "gdw-vault exec \"\(quotedName)\" -- \(command)\n\n(o exporta tú la variable: \(envVar)=… )"
    }

    private static func isValidEnvName(_ name: String) -> Bool {
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
