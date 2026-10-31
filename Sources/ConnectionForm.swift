import AppKit

// Formulario para crear y editar conexiones desde la app de barra de estado.
// Los campos extra dependen del protocolo: mysql/postgres aceptan base de datos
// (opcional); website pide URL (sin host ni puerto); ssh/sftp/ftp solo usan los campos base.
// En ssh/sftp se puede elegir autenticación por password o por llave guardada.
final class ConnectionForm: NSObject, NSWindowDelegate {
    private let store = Store.shared
    private var window: NSWindow!
    private var groupField: NSComboBox!
    private var nameField: NSTextField!
    private var hostField: NSTextField!
    private var portField: NSTextField!
    private var protoPopup: NSPopUpButton!
    private var userField: NSTextField!
    private var passField: NSSecureTextField!
    private var authPopup: NSPopUpButton!
    private var keyCombo: NSPopUpButton!
    private var copyPassButton: NSButton!
    private var dbField: NSTextField!
    private var modePopup: NSPopUpButton!
    private var sensitiveReadCheckbox: NSButton!
    private var modeRow: NSGridRow!
    private var sensitiveReadRow: NSGridRow!
    private var httpAuthPopup: NSPopUpButton!
    private var headerField: NSTextField!
    private var httpAuthRow: NSGridRow!
    private var headerRow: NSGridRow!
    private var urlField: NSTextField!
    private var notesField: NSTextField!
    private var authRow: NSGridRow!
    private var keyRow: NSGridRow!
    private var passRow: NSGridRow!
    private var hostRow: NSGridRow!
    private var portRow: NSGridRow!
    private var dbRow: NSGridRow!
    private var urlRow: NSGridRow!
    private var secretAccount: String?
    private var keyIds: [Int] = []
    private var editing: [String: Any]?

    // Retiene la instancia mientras la ventana no-modal esté abierta.
    private static var current: ConnectionForm?

    static let protocols = [
        "sftp", "ssh", "ftp", "ftpes", "ftps",
        "mysql", "postgres", "website", "api",
    ]
    static let dbProtocols: Set<String> = ["mysql", "postgres"]
    /// Protocolos con cliente HTTP (url + auth por token/cookie).
    static let httpProtocols: Set<String> = ["website", "api"]
    static let keyProtocols: Set<String> = ["ssh", "sftp"]
    static let authMethods = ["password", "key"]
    /// Autenticación HTTP: details["auth"] en website/api.
    static let httpAuthMethods = ["none", "basic", "bearer", "header", "query"]

    static func show(editing connection: [String: Any]? = nil, onSave: (() -> Void)? = nil) {
        let form = ConnectionForm()
        form.editing = connection
        form.onSave = onSave
        Self.current = form
        form.present()
    }

    private var onSave: (() -> Void)?

    private func present() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 550),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = editing == nil ? "Nueva conexión" : "Editar conexión"
        window.center()
        window.delegate = self
        // El formulario es el dueño de la ventana: si AppKit la libera al
        // cerrar, el ivar queda colgando y el dealloc crashea.
        window.isReleasedWhenClosed = false

        groupField = NSComboBox()
        groupField.isEditable = true
        for group in store.listGroups() {
            if let name = group["name"] as? String { groupField.addItem(withObjectValue: name) }
        }

        nameField = NSTextField()
        hostField = NSTextField()
        portField = NSTextField()
        userField = NSTextField()
        notesField = NSTextField()
        dbField = NSTextField()
        dbField.placeholderString = "(opcional)"

        modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: [
            "Lectura — solo consultas",
            "Info — bloquea y muestra cómo ejecutarlo",
            "Edición — escritura con confirmación",
            "Unsafe — todo con confirmación",
        ])
        httpAuthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        httpAuthPopup.addItems(withTitles: [
            "Sin autenticación",
            "Basic (usuario/password)",
            "Bearer token",
            "Header personalizado",
            "Query param",
        ])
        headerField = NSTextField()
        headerField.placeholderString = "Authorization / api_key (opcional)"
        urlField = NSTextField()
        passField = NSSecureTextField()
        passField.placeholderString = editing == nil ? "(opcional)" : "(dejar vacío para conservar)"
        sensitiveReadCheckbox = NSButton(checkboxWithTitle: "Permitir lectura de archivos sensibles",
                                         target: nil, action: nil)
        sensitiveReadCheckbox.toolTip = "Cada lectura requiere confirm=true. Touch ID se solicita al primer acceso y se reutiliza durante 15 min para esta conexión. No sustituye los permisos del servidor."

        copyPassButton = NSButton(title: "Copiar", target: self, action: #selector(copyStoredPassword))
        copyPassButton.bezelStyle = .rounded
        copyPassButton.controlSize = .small
        copyPassButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        copyPassButton.toolTip = "Copia el password guardado al portapapeles (pide Touch ID)."
        copyPassButton.isHidden = true

        let passStack = NSStackView(views: [passField, copyPassButton])
        passStack.orientation = .horizontal
        passStack.alignment = .firstBaseline
        passStack.spacing = 8

        keyCombo = NSPopUpButton(frame: .zero, pullsDown: false)
        keyIds = []
        for key in store.listKeys() {
            guard let name = key["name"] as? String, let id = key["id"] as? Int else { continue }
            keyCombo.addItem(withTitle: name)
            keyIds.append(id)
        }

        protoPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        protoPopup.addItems(withTitles: Self.protocols)

        authPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        authPopup.addItems(withTitles: ["Password", "Llave SSH"])

        if let conn = editing {
            nameField.stringValue = conn["name"] as? String ?? ""
            hostField.stringValue = conn["host"] as? String ?? ""
            portField.stringValue = (conn["port"] as? Int).map(String.init) ?? ""
            userField.stringValue = conn["username"] as? String ?? ""
            notesField.stringValue = conn["notes"] as? String ?? ""
            let proto = conn["protocol"] as? String ?? "sftp"
            protoPopup.selectItem(withTitle: proto)
            if let groupName = conn["group_name"] as? String { groupField.stringValue = groupName }
            let details = store.detailsDict(from: conn)
            dbField.stringValue = details["database"] ?? ""
            urlField.stringValue = details["url"] ?? ""
            if Self.httpProtocols.contains(proto) {
                let httpAuth = Self.httpAuthMethods.firstIndex(of: (details["auth"] ?? "none").lowercased()) ?? 0
                httpAuthPopup.selectItem(at: httpAuth)
                headerField.stringValue = details["header_name"] ?? details["query_param"] ?? ""
            }
            switch (details["mode"] ?? "lectura").lowercased() {
            case "unsafe": modePopup.selectItem(at: 3)
            case "edicion": modePopup.selectItem(at: 2)
            case "info": modePopup.selectItem(at: 1)
            default: modePopup.selectItem(at: 0) // lectura, y legacy "safe"
            }
            sensitiveReadCheckbox.state = details[SensitiveFilePolicy.connectionSetting] == "true"
                ? .on : .off
            if details["auth"] == "key", let keyId = conn["key_id"] as? Int,
               let index = keyIds.firstIndex(of: keyId) {
                authPopup.selectItem(at: 1)
                keyCombo.selectItem(at: index)
            }
            // El editor de lista no siempre trae keychain_account; resolverlo por id.
            secretAccount = (conn["keychain_account"] as? String)
                ?? store.findConnection(id: conn["id"] as? Int)?["keychain_account"] as? String
            if let account = secretAccount, KeychainStore.shared.hasSecret(account: account) {
                copyPassButton.isHidden = false
                passField.toolTip = "Hay un password guardado; usa «Copiar» para verlo."
            }
        } else {
            protoPopup.selectItem(withTitle: "sftp")
        }

        let rows: [(String, NSView)] = [
            ("Grupo", groupField as NSView),
            ("Protocolo", protoPopup),
            ("Nombre", nameField),
            ("URL", urlField),
            ("Base de datos", dbField),
            ("Host", hostField),
            ("Puerto", portField),
            ("Usuario", userField),
            ("Autenticación", authPopup),
            ("Llave", keyCombo),
            ("Auth HTTP", httpAuthPopup),
            ("Header/param", headerField),
            ("Password / token", passStack),
            ("Modo", modePopup),
            ("Permiso adicional", sensitiveReadCheckbox),
            ("Notas", notesField),
        ]
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        for (label, field) in rows {
            let labelView = NSTextField(labelWithString: label)
            labelView.alignment = .right
            grid.addRow(with: [labelView, field])
        }
        urlRow = grid.row(at: 3)
        dbRow = grid.row(at: 4)
        hostRow = grid.row(at: 5)
        portRow = grid.row(at: 6)
        authRow = grid.row(at: 8)
        keyRow = grid.row(at: 9)
        httpAuthRow = grid.row(at: 10)
        headerRow = grid.row(at: 11)
        passRow = grid.row(at: 12)
        modeRow = grid.row(at: 13)
        sensitiveReadRow = grid.row(at: 14)

        let save = NSButton(title: "Guardar", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancelar", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancel, save])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.spacing = 10

        let content = NSView()
        content.addSubview(grid)
        content.addSubview(buttons)
        window.contentView = content

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
        ])

        protoPopup.target = self
        protoPopup.action = #selector(protocolChanged)
        authPopup.target = self
        authPopup.action = #selector(protocolChanged)
        httpAuthPopup.target = self
        httpAuthPopup.action = #selector(protocolChanged)
        protocolChanged()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Libera la instancia cuando la ventana no-modal se cierra, pero DIFERIDO:
    // soltarla durante la animación de cierre crashea
    // (_NSWindowTransformAnimation sobre un objeto ya liberado).
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if Self.current === self { Self.current = nil }
        }
    }

    @objc private func protocolChanged() {
        let proto = protoPopup.titleOfSelectedItem ?? "sftp"
        let keyAuthAvailable = Self.keyProtocols.contains(proto)
        let usesKey = keyAuthAvailable && authPopup.indexOfSelectedItem == 1
        authRow.isHidden = !keyAuthAvailable
        keyRow.isHidden = !usesKey
        passRow.isHidden = usesKey
        let isHTTP = Self.httpProtocols.contains(proto)
        hostRow.isHidden = isHTTP
        portRow.isHidden = isHTTP
        dbRow.isHidden = !Self.dbProtocols.contains(proto)
        urlRow.isHidden = !Self.httpProtocols.contains(proto)
        httpAuthRow.isHidden = !Self.httpProtocols.contains(proto)
        headerRow.isHidden = !Self.httpProtocols.contains(proto)
            || ![3, 4].contains(httpAuthPopup.indexOfSelectedItem)
        // El modo aplica a BD (SQL), ssh/sftp (comandos remotos) y HTTP.
        modeRow.isHidden = !(Self.dbProtocols.contains(proto)
            || Self.keyProtocols.contains(proto) || Self.httpProtocols.contains(proto))
        sensitiveReadRow.isHidden = !Self.keyProtocols.contains(proto)
    }

    @objc private func copyStoredPassword() {
        guard let account = secretAccount else { return }
        let name = editing?["name"] as? String ?? "la conexión"
        guard TouchId.authorizeSync(reason: "GDW Vault: copiar el password de \"\(name)\" al portapapeles.") else {
            showResult(success: false, message: "Touch ID rechazado.")
            return
        }
        guard let secret = KeychainStore.shared.getSecret(account: account) else {
            showResult(success: false, message: "No hay password guardado.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(secret, forType: .string)
        showResult(success: true, message: "Password copiado al portapapeles. Se borrará cuando copies otra cosa.")
    }

    @objc private func cancel() {
        window.close()
    }

    private func showResult(success: Bool, message: String) {
        let alert = NSAlert()
        alert.messageText = success ? "✓ Prueba de acceso" : "✕ Prueba de acceso"
        alert.informativeText = message
        alert.alertStyle = success ? .informational : .critical
        alert.runModal()
    }

    @objc private func save() {
        let groupName = groupField.stringValue.trimmingCharacters(in: .whitespaces)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let notes = notesField.stringValue.trimmingCharacters(in: .whitespaces)
        let proto = protoPopup.titleOfSelectedItem ?? "sftp"
        let secret = passField.stringValue
        let database = dbField.stringValue.trimmingCharacters(in: .whitespaces)
        let url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
        let usesKeyAuth = Self.keyProtocols.contains(proto) && authPopup.indexOfSelectedItem == 1

        guard !groupName.isEmpty, !name.isEmpty else {
            showError("Los campos «Grupo» y «Nombre» son obligatorios.")
            return
        }
        var port: Int?
        if !portField.stringValue.isEmpty {
            guard let value = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)), value > 0, value <= 65535 else {
                showError("El puerto debe ser un número entre 1 y 65535.")
                return
            }
            port = value
        }
        var details: [String: String] = [:]
        if Self.dbProtocols.contains(proto), !database.isEmpty {
            details["database"] = database
        }
        if Self.dbProtocols.contains(proto) || Self.keyProtocols.contains(proto) {
            details["mode"] = ["lectura", "info", "edicion", "unsafe"][modePopup.indexOfSelectedItem]
        }
        if Self.httpProtocols.contains(proto), !url.isEmpty {
            details["url"] = url
        }
        if Self.httpProtocols.contains(proto) {
            let httpAuth = Self.httpAuthMethods[max(0, min(httpAuthPopup.indexOfSelectedItem, 4))]
            if httpAuth != "none" { details["auth"] = httpAuth }
            let extra = headerField.stringValue.trimmingCharacters(in: .whitespaces)
            if !extra.isEmpty {
                if httpAuth == "header" { details["header_name"] = extra }
                if httpAuth == "query" { details["query_param"] = extra }
            }
        }
        if Self.keyProtocols.contains(proto) {
            details["auth"] = usesKeyAuth ? "key" : "password"
            if sensitiveReadCheckbox.state == .on {
                details[SensitiveFilePolicy.connectionSetting] = "true"
            }
        }
        var keyId: Int?
        if usesKeyAuth {
            let index = keyCombo.indexOfSelectedItem
            guard index >= 0, index < keyIds.count else {
                showError("Selecciona una llave para la autenticación por llave (o créala en «Llaves de acceso…»).")
                return
            }
            keyId = keyIds[index]
        }

        if let id = editing?["id"] as? Int {
            let ok = store.updateConnection(id: id, groupId: store.upsertGroup(groupName), name: name,
                                            host: host.isEmpty ? nil : host, port: port,
                                            protocolType: proto, username: user.isEmpty ? nil : user,
                                            secret: secret.isEmpty ? nil : secret, notes: notes.isEmpty ? nil : notes,
                                            details: details.isEmpty ? nil : details, keyId: keyId)
            guard ok else {
                showError("No se pudo actualizar la conexión (¿nombre duplicado en el grupo?).")
                return
            }
        } else {
            _ = store.upsertConnection(groupId: store.upsertGroup(groupName), name: name,
                                       host: host.isEmpty ? nil : host, port: port,
                                       protocolType: proto, username: user.isEmpty ? nil : user,
                                       secret: secret.isEmpty ? nil : secret, notes: notes.isEmpty ? nil : notes,
                                       details: details.isEmpty ? nil : details, keyId: keyId)
        }

        // Igual que el importador: escribir el secreto no pide Touch ID;
        // la huella es la puerta para leerlo/copiarlo después.
        onSave?()
        window.close()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Datos incompletos"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
