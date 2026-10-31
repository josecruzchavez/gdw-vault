import AppKit

// Ventana de administración de conexiones: tabla con todas las conexiones,
// buscador y acciones de crear / editar / eliminar.
final class ConnectionManager: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = ConnectionManager()
    private let store = Store.shared
    private var window: NSWindow!
    private var tableView: NSTableView!
    private var searchField: NSSearchField!
    private var newButton: NSButton!
    private var editButton: NSButton!
    private var deleteButton: NSButton!
    private var keysButton: NSButton!
    private var rows: [[String: Any]] = []

    private enum Column {
        static let group = "group"
        static let name = "name"
        static let proto = "protocol"
        static let host = "host"
        static let user = "user"
        static let auth = "auth"
    }

    func show() {
        if window == nil { buildWindow() }
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Construcción de la ventana

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Conexiones — GDW Vault"
        window.minSize = NSSize(width: 560, height: 320)
        window.center()

        searchField = NSSearchField()
        searchField.placeholderString = "Buscar por grupo, nombre, host o usuario…"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(editSelected)
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true

        for (id, title, width) in [
            (Column.group, "Grupo", 140.0),
            (Column.name, "Nombre", 150.0),
            (Column.proto, "Protocolo", 85.0),
            (Column.host, "Host", 170.0),
            (Column.user, "Usuario", 130.0),
            (Column.auth, "Auth", 70.0),
        ] as [(String, String, CGFloat)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 60
            tableView.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tableView.sizeLastColumnToFit()

        newButton = NSButton(title: "Nueva conexión…", target: self, action: #selector(newConnection))
        newButton.bezelStyle = .rounded
        newButton.keyEquivalent = "n"
        editButton = NSButton(title: "Editar", target: self, action: #selector(editSelected))
        editButton.bezelStyle = .rounded
        deleteButton = NSButton(title: "Eliminar", target: self, action: #selector(deleteSelected))
        deleteButton.bezelStyle = .rounded
        keysButton = NSButton(title: "Llaves de acceso…", target: self, action: #selector(openKeys))
        keysButton.bezelStyle = .rounded
        let close = NSButton(title: "Cerrar", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [newButton, editButton, deleteButton, keysButton, NSView(), close])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.spacing = 10
        buttons.distribution = .fill

        let content = NSView()
        content.addSubview(searchField)
        content.addSubview(scroll)
        content.addSubview(buttons)
        window.contentView = content

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        updateButtons()
    }

    // MARK: - Datos

    private func reload() {
        let all = store.listConnections()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = query.isEmpty ? all : all.filter { row in
            ["group_name", "name", "protocol", "host", "username"].contains { key in
                (row[key] as? String)?.lowercased().contains(query) ?? false
            }
        }
        tableView.reloadData()
        updateButtons()
    }

    private func selectedRow() -> [String: Any]? {
        let index = tableView.selectedRow
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    private func updateButtons() {
        let hasSelection = tableView.selectedRow >= 0
        editButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < rows.count, let id = tableColumn?.identifier.rawValue else { return nil }
        switch id {
        case Column.group: return rows[row]["group_name"] as? String
        case Column.name: return rows[row]["name"] as? String
        case Column.proto: return rows[row]["protocol"] as? String
        case Column.host: return rows[row]["host"] as? String
        case Column.user: return rows[row]["username"] as? String
        case Column.auth:
            let details = store.detailsDict(from: rows[row])
            return details["auth"] == "key" ? "🔑 llave" : "password"
        default: return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: - Acciones

    @objc private func searchChanged() { reload() }

    @objc private func newConnection() {
        ConnectionForm.show(onSave: { [weak self] in self?.reload() })
    }

    @objc private func openKeys() {
        KeysManager.shared.show()
    }

    @objc private func editSelected() {
        guard let conn = selectedRow() else { return }
        ConnectionForm.show(editing: conn, onSave: { [weak self] in self?.reload() })
    }

    @objc private func deleteSelected() {
        guard let conn = selectedRow(), let id = conn["id"] as? Int else { return }
        let name = conn["name"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "¿Eliminar «\(name)»?"
        alert.informativeText = "Se borra la conexión y su password del Keychain. Esta acción no se puede deshacer."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Eliminar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = store.deleteConnection(id: id)
        reload()
    }

    @objc private func closeWindow() {
        // orderOut en lugar de performClose: sin animación de cierre.
        window.orderOut(nil)
    }
}
