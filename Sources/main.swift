import AppKit

@main
struct VaultMain {
    static func main() {
        let args = CommandLine.arguments

        // Modo servidor MCP para VS Code: gdw-vault --mcp
        if args.contains("--mcp") {
            guard UsageNotice.requireAcceptance() else { return }
            setvbuf(stdout, nil, _IOLBF, 0)
            McpServer().run()
            return
        }

        // Modo CLI: importar FileZilla sin UI: gdw-vault import /ruta/sites.xml
        if let index = args.firstIndex(of: "import"), index + 1 < args.count {
            let path = args[index + 1]
            do {
                let summary = try FileZillaImporter().importFile(at: path)
                print("✓ Importación completada:")
                print("  Grupos: \(summary.groups)")
                print("  Conexiones: \(summary.connections)")
                print("  Omitidas: \(summary.skipped)")
                return
            } catch {
                FileHandle.standardError.write(Data("✕ \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }

        // Modo CLI: ejecutar un comando con el secreto inyectado:
        // gdw-vault exec "Nombre" [--env VAR] [--stdin] [--timeout N] -- <comando…>
        if let index = args.firstIndex(of: "exec") {
            guard index + 1 < args.count else {
                FileHandle.standardError.write(Data("✕ Uso: gdw-vault exec \"Nombre\" [--env VAR] [--stdin] [--timeout N] -- <comando…>\n".utf8))
                exit(1)
            }
            let name = args[index + 1]
            var envVar: String?
            var viaStdin = false
            var timeout = SecretBroker.defaultTimeout
            var commandParts: [String] = []
            var cursor = index + 2
            while cursor < args.count {
                let arg = args[cursor]
                if arg == "--" {
                    commandParts = Array(args[(cursor + 1)...])
                    break
                }
                if arg == "--env", cursor + 1 < args.count {
                    envVar = args[cursor + 1]
                    cursor += 2
                    continue
                }
                if arg == "--stdin" {
                    viaStdin = true
                    cursor += 1
                    continue
                }
                if arg == "--timeout", cursor + 1 < args.count {
                    timeout = Int(args[cursor + 1]) ?? timeout
                    cursor += 2
                    continue
                }
                commandParts = Array(args[cursor...])
                break
            }
            guard !commandParts.isEmpty else {
                FileHandle.standardError.write(Data("✕ Uso: gdw-vault exec \"Nombre\" [--env VAR] [--stdin] [--timeout N] -- <comando…>\n".utf8))
                exit(1)
            }
            let outcome = SecretBroker().run(
                connectionName: name,
                command: commandParts.joined(separator: " "),
                envVar: envVar, viaStdin: viaStdin,
                confirm: true, timeout: timeout, operatorOverride: true)
            if outcome.ok {
                print(outcome.message)
            } else {
                FileHandle.standardError.write(Data("✕ \(outcome.message)\n".utf8))
                exit(1)
            }
            return
        }

        // Modo CLI: listar conexiones
        if args.contains("list") {
            for conn in Store.shared.listConnections() {
                let group = conn["group_name"] as? String ?? "-"
                let name = conn["name"] as? String ?? "-"
                let host = conn["host"] as? String ?? "-"
                let user = conn["username"] as? String ?? "-"
                print("\(group) :: \(name) :: \(host) :: \(user)")
            }
            return
        }

        // Modo CLI: eliminar conexión por id: gdw-vault delete 14
        if let index = args.firstIndex(of: "delete"), index + 1 < args.count {
            guard let id = Int(args[index + 1]) else {
                FileHandle.standardError.write(Data("✕ El id debe ser un número entero\n".utf8))
                exit(1)
            }
            if Store.shared.deleteConnection(id: id) {
                print("✓ Conexión \(id) eliminada (y su secreto del Keychain)")
            } else {
                FileHandle.standardError.write(Data("✕ No se encontró la conexión \(id)\n".utf8))
                exit(1)
            }
            return
        }

        // Modo CLI: versión
        if args.contains("--version") || args.contains("version") {
            print("GDW Vault \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "desarrollo")")
            return
        }

        // Modo GUI por defecto: barra de estado
        guard StatusInstanceLock.acquire() else {
            NSLog("GDW Vault ya tiene una instancia de barra de estado activa")
            return
        }
        guard UsageNotice.requireAcceptance() else { return }
        let app = NSApplication.shared
        let delegate = StatusUI()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
