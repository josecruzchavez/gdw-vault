import AppKit
import UniformTypeIdentifiers

// Ventana de administración de llaves de acceso SSH: tabla + alta/edición/baja,
// con selector de archivos para la llave pública y la privada.
final class KeysManager: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = KeysManager()
    private let store = Store.shared
    private var window: NSWindow!
    private var tableView: NSTableView!
    private var newButton: NSButton!
    private var editButton: NSButton!
    private var deleteButton: NSButton!
    private var rows: [[String: Any]] = []

    private enum Column {
        static let name = "name"
        static let pub = "pub"
        static let secret = "secret"
    }

    func show() {
        if window == nil { buildWindow() }
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Ventana

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Llaves de acceso — GDW Vault"
        window.minSize = NSSize(width: 540, height: 280)
        window.center()

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(editSelected)
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = true

        for (id, title, width) in [
            (Column.name, "Nombre", 160.0),
            (Column.pub, "Llave pública", 240.0),
            (Column.secret, "Llave privada", 240.0),
        ] as [(String, String, CGFloat)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 80
            tableView.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tableView.sizeLastColumnToFit()

        newButton = NSButton(title: "Nueva llave…", target: self, action: #selector(newKey))
        newButton.bezelStyle = .rounded
        newButton.keyEquivalent = "n"
        editButton = NSButton(title: "Editar", target: self, action: #selector(editSelected))
        editButton.bezelStyle = .rounded
        deleteButton = NSButton(title: "Eliminar", target: self, action: #selector(deleteSelected))
        deleteButton.bezelStyle = .rounded
        let close = NSButton(title: "Cerrar", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [newButton, editButton, deleteButton, NSView(), close])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.spacing = 10
        buttons.distribution = .fill

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(buttons)
        window.contentView = content

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        updateButtons()
    }

    private func reload() {
        rows = store.listKeys()
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
        case Column.name: return rows[row]["name"] as? String
        case Column.pub: return rows[row]["pub_path"] as? String
        case Column.secret: return rows[row]["secret_path"] as? String
        default: return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: - Acciones

    @objc private func newKey() {
        KeyForm.show(onSave: { [weak self] in self?.reload() })
    }

    @objc private func editSelected() {
        guard let key = selectedRow() else { return }
        KeyForm.show(editing: key, onSave: { [weak self] in self?.reload() })
    }

    @objc private func deleteSelected() {
        guard let key = selectedRow(), let id = key["id"] as? Int else { return }
        let name = key["name"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "¿Eliminar la llave «\(name)»?"
        alert.informativeText = "Las conexiones que la usaban volverán a autenticarse por password. Los archivos de llave no se borran del disco."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Eliminar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = store.deleteKey(id: id)
        reload()
    }

    @objc private func closeWindow() {
        // orderOut en lugar de performClose: sin animación de cierre.
        window.orderOut(nil)
    }

    // La ventana se conserva en caché: liberarla en windowWillClose crashea
    // si la animación de cierre sigue en curso.
}

// Formulario para crear/editar una llave de acceso (ventana no-modal).
private final class KeyForm: NSObject, NSWindowDelegate {
    private static var current: KeyForm?
    private let store = Store.shared
    private var onSave: (() -> Void)?
    private var window: NSWindow!
    private var nameField: NSTextField!
    private var pubField: NSTextField!
    private var secretField: NSTextField!
    private var notesField: NSTextField!
    private var editing: [String: Any]?

    static func show(editing key: [String: Any]? = nil, onSave: (() -> Void)? = nil) {
        let form = KeyForm()
        form.editing = key
        form.onSave = onSave
        Self.current = form
        form.present()
    }

    private func present() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = editing == nil ? "Nueva llave" : "Editar llave"
        window.center()
        window.delegate = self
        // El formulario es el dueño de la ventana (ver ConnectionForm).
        window.isReleasedWhenClosed = false

        nameField = NSTextField()
        pubField = NSTextField()
        secretField = NSTextField()
        notesField = NSTextField()

        if let key = editing {
            nameField.stringValue = key["name"] as? String ?? ""
            pubField.stringValue = key["pub_path"] as? String ?? ""
            secretField.stringValue = key["secret_path"] as? String ?? ""
            notesField.stringValue = key["notes"] as? String ?? ""
        }

        let rows: [(String, NSView, NSView?)] = [
            ("Nombre", nameField, nil),
            ("Llave pública", pubField, browseButton(#selector(browsePub))),
            ("Llave privada", secretField, browseButton(#selector(browseSecret))),
            ("Notas", notesField, nil),
        ]
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        for (label, field, extra) in rows {
            let labelView = NSTextField(labelWithString: label)
            labelView.alignment = .right
            grid.addRow(with: [labelView, field, extra ?? NSView()])
        }

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

    private func browseButton(_ action: Selector) -> NSButton {
        let button = NSButton(title: "Examinar…", target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func browsePub() {
        browse(into: pubField)
    }

    @objc private func browseSecret() {
        browse(into: secretField)
    }

    private func browse(into field: NSTextField) {
        let panel = NSOpenPanel()
        panel.title = "Selecciona el archivo de llave"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.data]
        if panel.runModal() == .OK, let url = panel.url {
            field.stringValue = url.path
        }
    }

    @objc private func cancel() {
        window.close()
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let pub = pubField.stringValue.trimmingCharacters(in: .whitespaces)
        let secret = secretField.stringValue.trimmingCharacters(in: .whitespaces)
        let notes = notesField.stringValue.trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty else {
            showError("El campo «Nombre» es obligatorio.")
            return
        }
        guard !secret.isEmpty else {
            showError("La «Llave privada» es obligatoria (es la que usa ssh -i).")
            return
        }
        for (label, path) in [("Llave pública", pub), ("Llave privada", secret)] where !path.isEmpty {
            guard FileManager.default.fileExists(atPath: path) else {
                showError("\(label): el archivo no existe — \(path)")
                return
            }
        }

        let id = editing?["id"] as? Int
        let keyId = store.upsertKey(id: id, name: name,
                                    pubPath: pub.isEmpty ? nil : pub,
                                    secretPath: secret,
                                    notes: notes.isEmpty ? nil : notes)
        guard keyId > 0 else {
            showError("No se pudo guardar la llave (¿nombre duplicado?).")
            return
        }
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
