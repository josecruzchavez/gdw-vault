import Foundation

/// Importador de archivos sites.xml de FileZilla.
/// Estructura: FileZilla3 > Servers > (Folder*)* > Server
/// Las carpetas anidadas se aplanan como grupos "Padre / Hijo".
final class FileZillaImporter {
    struct Summary {
        var groups = 0
        var connections = 0
        var skipped = 0
        var errors: [String] = []
    }

    private let store = Store.shared

    /// Protocolos según el enum de FileZilla: 0=FTP, 1=SFTP, 3=FTPES, 4=FTPS, 6=FTP vía proxy.
    private func protocolName(_ raw: String?) -> String {
        switch raw {
        case "1": return "sftp"
        case "3": return "ftpes"
        case "4": return "ftps"
        default: return "ftp"
        }
    }

    private func text(_ element: XMLElement, _ tag: String) -> String? {
        element.elements(forName: tag).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodePassword(_ element: XMLElement) -> String? {
        guard let passEl = element.elements(forName: "Pass").first,
              let raw = passEl.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        if passEl.attribute(forName: "encoding")?.stringValue == "base64" {
            return Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? raw
        }
        return raw
    }

    /// Nombre de carpeta: el primer nodo de texto del Folder (los hijos Server son elementos, no texto).
    private func folderName(_ folder: XMLElement) -> String? {
        folder.children?
            .first(where: { $0.kind == .text })
            .flatMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    func importFile(at path: String) throws -> Summary {
        let summary = Summary()
        let doc = try XMLDocument(contentsOf: URL(fileURLWithPath: path), options: [])
        guard let servers = doc.rootElement()?.elements(forName: "Servers").first else {
            throw NSError(domain: "GDWVault", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "El XML no contiene <Servers>"])
        }

        var result = summary
        for child in servers.children ?? [] where child.kind == .element {
            if let folder = child as? XMLElement, folder.name == "Folder" {
                walk(folder: folder, path: [], summary: &result)
            } else if let server = child as? XMLElement, server.name == "Server" {
                importServer(server, groupName: "Sin carpeta", summary: &result)
            }
        }
        result.groups = store.listGroups().count
        return result
    }

    private func walk(folder: XMLElement, path: [String], summary: inout Summary) {
        guard let name = folderName(folder) else {
            summary.skipped += 1
            return
        }
        let newPath = path + [name]
        let groupLabel = newPath.joined(separator: " / ")

        for child in folder.children ?? [] where child.kind == .element {
            if let sub = child as? XMLElement, sub.name == "Folder" {
                walk(folder: sub, path: newPath, summary: &summary)
            } else if let server = child as? XMLElement, server.name == "Server" {
                importServer(server, groupName: groupLabel, summary: &summary)
            }
        }
    }

    private func importServer(_ server: XMLElement, groupName: String, summary: inout Summary) {
        guard let name = text(server, "Name"), !name.isEmpty else {
            summary.skipped += 1
            return
        }
        let host = text(server, "Host")
        let port = text(server, "Port").flatMap(Int.init)
        let user = text(server, "User")
        let protocolType = protocolName(text(server, "Protocol"))
        let secret = decodePassword(server)

        let groupId = store.upsertGroup(groupName)
        store.upsertConnection(groupId: groupId, name: name, host: host, port: port,
                               protocolType: protocolType, username: user, secret: secret, notes: nil)
        summary.connections += 1
    }
}
