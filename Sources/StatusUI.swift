import AppKit
import UniformTypeIdentifiers

final class StatusUI: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var menu: NSMenu!
    private let databaseService = DatabaseService()
    private let store = Store.shared
    private let importer = FileZillaImporter()
    private let aboutLinks: [(title: String, address: String)] = [
        ("josecruzchavez.com", "https://josecruzchavez.com"),
        ("Sitio del proyecto · vault.gdw.mx", "https://vault.gdw.mx"),
        ("GDW · desarrollos", "https://gdw.mx"),
        ("Código fuente en GitHub", "https://github.com/josecruzchavez/gdw-vault")
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        databaseService.start()
        MainThreadWatchdog.shared.start()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        let icon = statusIcon()
        item.button?.image = icon
        item.button?.toolTip = "GDW Vault (nativo)"

        rebuild()

    }

    /// Icono de la barra de menús: template image (negro + alfa); macOS la pinta
    /// negro en barra clara y blanco en barra oscura automáticamente.
    private func statusIcon() -> NSImage {
        if let img = NSImage(named: "StatusIcon") {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        // Fallback si el recurso no está en el bundle.
        let fallback = NSImage(systemSymbolName: "lock", accessibilityDescription: "GDW Vault")!
        return fallback.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!
    }

    private func rebuild() {
        menu.removeAllItems()

        let header = NSMenuItem(title: "GDW Vault — vault local", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let importItem = NSMenuItem(title: "Importar de FileZilla (.xml)…", action: #selector(chooseImportFile), keyEquivalent: "i")
        importItem.target = self
        menu.addItem(importItem)

        let manage = NSMenuItem(title: "Administrar conexiones…", action: #selector(openManager), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)

        let count = store.listConnections().count
        let stats = NSMenuItem(title: count == 0 ? "Vault vacío — importa tus accesos" : "\(count) conexiones guardadas", action: nil, keyEquivalent: "")
        stats.isEnabled = false
        menu.addItem(stats)
        menu.addItem(.separator())

        // Grupos con sus conexiones como submenús
        for group in store.listGroups() {
            let groupName = group["name"] as? String ?? "?"
            let groupItem = NSMenuItem(title: "📁 \(groupName)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let connections = store.listConnections(groupId: group["id"] as? Int)
            for conn in connections {
                let connName = conn["name"] as? String ?? "?"
                let proto = conn["protocol"] as? String ?? ""
                let connItem = NSMenuItem(title: "\(protoIcon(proto)) \(connName)", action: #selector(openConnection(_:)), keyEquivalent: "")
                connItem.target = self
                connItem.representedObject = conn["id"] as? Int
                submenu.addItem(connItem)
            }
            if connections.isEmpty {
                let empty = NSMenuItem(title: "(vacío)", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                submenu.addItem(empty)
            }
            groupItem.submenu = submenu
            menu.addItem(groupItem)
        }

        menu.addItem(.separator())
        let about = NSMenuItem(title: "Acerca de", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func protoIcon(_ proto: String) -> String {
        switch proto {
        case "sftp", "ssh": return "🖥"
        case "ftp", "ftpes", "ftps": return "📂"
        case "mysql", "postgres": return "🗄"
        case "website", "admin", "api": return "🌐"
        default: return "🔗"
        }
    }

    // MARK: - Actions

    @objc private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.title = "Selecciona el sites.xml de FileZilla"
        panel.allowedContentTypes = [UTType.xml]
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.runImport(path: path, showAlert: true)
        }
    }

    @discardableResult
    func runImport(path: String, showAlert: Bool) -> FileZillaImporter.Summary? {
        do {
            let summary = try importer.importFile(at: path)
            if showAlert { showImportSummary(summary) }
            return summary
        } catch {
            if showAlert {
                let alert = NSAlert(error: error)
                alert.runModal()
            } else {
                FileHandle.standardError.write(Data("Import error: \(error.localizedDescription)\n".utf8))
            }
            return nil
        }
    }

    private func showImportSummary(_ summary: FileZillaImporter.Summary) {
        let alert = NSAlert()
        alert.messageText = "Importación completada"
        alert.informativeText = """
        Grupos: \(summary.groups)
        Conexiones importadas: \(summary.connections)
        Omitidas: \(summary.skipped)
        Los secretos quedaron en el Keychain de macOS.
        """
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func openConnection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int,
              store.findConnection(id: id) != nil else { return }
        showConnectionDetails(id: id)
    }

    private func showConnectionDetails(id: Int) {
        while let conn = store.findConnection(id: id) {
            let name = conn["name"] as? String ?? "?"
            let group = conn["group_name"] as? String ?? ""
            let host = conn["host"] as? String ?? "-"
            let port = (conn["port"] as? Int).map(String.init) ?? "-"
            let user = conn["username"] as? String ?? "-"
            let proto = conn["protocol"] as? String ?? "-"

            var extras = ""
            let details = store.detailsDict(from: conn)
            let usesKeyAuth = details["auth"] == "key"
            let supportsSensitiveRead = ["ssh", "sftp"].contains(proto.lowercased())
            let sensitiveReadEnabled = SensitiveFilePolicy.isEnabled(in: details)
            if let database = details["database"], !database.isEmpty {
                extras += "\nBase de datos: \(database)"
            }
            if let url = details["url"], !url.isEmpty {
                extras += "\nURL: \(url)"
            }
            if usesKeyAuth {
                let keyName = (conn["key_id"] as? Int)
                    .flatMap { store.findKey(id: $0)?["name"] as? String } ?? "no disponible"
                extras += "\nAutenticación: 🔑 llave «\(keyName)»"
            }
            if supportsSensitiveRead {
                extras += "\nLectura de archivos sensibles: \(sensitiveReadEnabled ? "permitida" : "bloqueada")"
            }

            let alert = NSAlert()
            alert.messageText = name
            alert.informativeText = """
            Grupo: \(group)
            Protocolo: \(proto)
            Host: \(host)
            Puerto: \(port)
            Usuario: \(user)\(extras)
            """
            if usesKeyAuth {
                alert.addButton(withTitle: "Copiar comando de conexión")
            } else {
                alert.addButton(withTitle: "Copiar password")
                alert.addButton(withTitle: "Copiar comando de conexión")
            }
            if supportsSensitiveRead {
                alert.addButton(withTitle: sensitiveReadEnabled
                    ? "Desactivar lectura de archivos sensibles"
                    : "Permitir lectura de archivos sensibles")
            }
            alert.addButton(withTitle: "Editar…")
            alert.addButton(withTitle: "Eliminar…")
            alert.addButton(withTitle: "Cerrar")
            alert.alertStyle = .informational

            let response = alert.runModal()
            let copyActionCount = usesKeyAuth ? 1 : 2
            let firstButtonResponse = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let permissionResponse = NSApplication.ModalResponse(
                rawValue: firstButtonResponse + copyActionCount)
            if supportsSensitiveRead && response == permissionResponse {
                guard store.setSensitiveFileReadAccess(
                    connectionId: id, enabled: !sensitiveReadEnabled) else {
                    infoAlert(
                        "No se pudo actualizar el permiso",
                        "Inténtalo otra vez o edita la conexión.",
                        warning: true)
                    continue
                }
                continue
            }

            let editResponse = NSApplication.ModalResponse(
                rawValue: firstButtonResponse + copyActionCount + (supportsSensitiveRead ? 1 : 0))
            let deleteResponse = NSApplication.ModalResponse(
                rawValue: firstButtonResponse + copyActionCount + (supportsSensitiveRead ? 2 : 1))
            switch response {
            case .alertFirstButtonReturn:
                if usesKeyAuth {
                    copyConnectionCommand(connection: conn)
                } else {
                    copyPassword(connection: conn)
                }
                return
            case .alertSecondButtonReturn where !usesKeyAuth:
                copyConnectionCommand(connection: conn)
                return
            case let selected where selected == editResponse:
                if let currentConnection = store.findConnection(id: id) {
                    ConnectionForm.show(editing: currentConnection)
                } else {
                    infoAlert("Conexión no disponible", "La conexión ya no existe.", warning: true)
                }
                return
            case let selected where selected == deleteResponse:
                confirmDelete(connection: conn)
                return
            default:
                return
            }
        }

        infoAlert("Conexión no disponible", "La conexión ya no existe.", warning: true)
    }

    @objc private func newConnection() {
        ConnectionForm.show()
    }

    @objc private func openManager() {
        // Diferido: abrir ventanas dentro del callstack de cierre del menú
        // de la barra de estado corrompe el estado de animación de AppKit.
        DispatchQueue.main.async {
            ConnectionManager.shared.show()
        }
    }

    @objc private func openKeys() {
        DispatchQueue.main.async {
            KeysManager.shared.show()
        }
    }

    private func confirmDelete(connection: [String: Any]) {
        guard let id = connection["id"] as? Int else { return }
        let name = connection["name"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "¿Eliminar «\(name)»?"
        alert.informativeText = "Se borra la conexión y su password del Keychain. Esta acción no se puede deshacer."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Eliminar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = store.deleteConnection(id: id)
        }
    }

    /// Arma el comando de conexión según el protocolo (sin password: la
    /// terminal lo pedirá al conectar).
    private func connectionCommand(_ conn: [String: Any]) -> String? {
        ConnectionCommandBuilder.build(conn)
    }

    private func copyConnectionCommand(connection: [String: Any]) {
        guard let command = connectionCommand(connection) else {
            let usesKeyAuth = store.detailsDict(from: connection)["auth"] == "key"
            if usesKeyAuth {
                infoAlert(
                    "Ruta de llave no disponible",
                    "No se encontró la ruta de llave privada asociada. Revisa «Llaves de acceso…».",
                    warning: true)
            } else {
                infoAlert(
                    "Sin comando para este protocolo",
                    "No hay un comando disponible para este tipo de conexión.",
                    warning: true)
            }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let name = connection["name"] as? String ?? "?"
        let usesKeyAuth = store.detailsDict(from: connection)["auth"] == "key"
        let authHint = usesKeyAuth
            ? "El comando usa la llave SSH configurada."
            : "La terminal te pedirá el password al conectar."
        let alert = NSAlert()
        alert.messageText = "Comando copiado — \(name)"
        alert.informativeText = "\(command)\n\n\(authHint)"
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Sincronización iCloud

    /// URL del snapshot en iCloud Drive (nil si iCloud no está disponible).
    private func icloudSnapshotURL() -> URL? {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/GDWVault")
        return dir.appendingPathComponent("vault-snapshot.json")
    }

    private func infoAlert(_ title: String, _ message: String, warning: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = warning ? .warning : .informational
        alert.runModal()
    }

    private func copyPassword(connection: [String: Any]) {
        let name = connection["name"] as? String ?? "la conexión"
        TouchId.authorize(reason: "GDW Vault: copiar el password de \"\(name)\" al portapapeles.") { [weak self] granted in
            DispatchQueue.main.async {
                guard granted, let secret = self?.store.secretFor(connection: connection) else { return }
                AuthSession.shared.markSecretUsed(account: connection["keychain_account"] as? String ?? "")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(secret, forType: .string)
                let alert = NSAlert()
                alert.messageText = "Password copiado al portapapeles"
                alert.informativeText = "Se borrará cuando copies otra cosa."
                alert.alertStyle = .informational
                alert.runModal()
            }
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Desarrollo"
        alert.messageText = "GDW Vault"
        alert.informativeText = """
        Versión \(version)

        Bóveda local para administrar conexiones y usar tus accesos desde macOS o asistentes compatibles con MCP.

        DATOS Y PROTECCIÓN
        • SQLite guarda grupos y metadatos de conexión.
        • El Llavero de macOS protege passwords y tokens.
        • Touch ID autoriza el acceso a secretos y otras acciones sensibles.

        INTEGRACIÓN
        • Servidor MCP local: gdw-vault --mcp
        • Importación de conexiones desde FileZilla.

        Los datos se guardan en esta Mac. La sincronización con iCloud está desactivada.

        Desarrollado por GDW · José Cruz Chávez
        """
        alert.alertStyle = .informational
        let linksView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 94))
        for (index, link) in aboutLinks.enumerated() {
            let button = NSButton(title: link.title, target: self, action: #selector(openAboutLinkButton(_:)))
            button.frame = NSRect(x: 0, y: CGFloat(3 - index) * 24, width: 300, height: 22)
            button.isBordered = false
            button.alignment = .left
            button.tag = index
            button.attributedTitle = NSAttributedString(
                string: link.title,
                attributes: [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            )
            linksView.addSubview(button)
        }
        alert.accessoryView = linksView
        alert.addButton(withTitle: "Cerrar")
        alert.runModal()
    }

    @objc private func openAboutLinkButton(_ sender: NSButton) {
        guard aboutLinks.indices.contains(sender.tag) else {
            assertionFailure("Índice de enlace inválido en Acerca de")
            return
        }
        openAboutLink(aboutLinks[sender.tag].address)
    }

    private func openAboutLink(_ address: String) {
        guard let url = URL(string: address), NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "No se pudo abrir el enlace"
            alert.informativeText = address
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
    }
}
