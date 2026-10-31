import Foundation

/// Construye el comando de terminal para conectarse según el protocolo.
/// Sin password por defecto (la terminal lo pedirá); con password incrustado
/// solo donde el cliente lo permite (mysql, postgres).
enum ConnectionCommandBuilder {
    static func build(_ conn: [String: Any], password: String? = nil) -> String? {
        let proto = conn["protocol"] as? String ?? ""
        let host = conn["host"] as? String ?? ""
        let user = conn["username"] as? String ?? ""
        let port = conn["port"] as? Int
        let details = Store.shared.detailsDict(from: conn)
        let db = details["database"] ?? ""
        let escaped = password.map { $0.replacingOccurrences(of: "'", with: "'\\''") }

        switch proto {
        case "ssh", "sftp":
            var cmd = "ssh"
            if details["auth"] == "key" {
                guard let keyId = conn["key_id"] as? Int,
                      let key = Store.shared.findKey(id: keyId),
                      let keyPath = key["secret_path"] as? String,
                      !keyPath.isEmpty else { return nil }
                let expandedPath = (keyPath as NSString).expandingTildeInPath
                cmd += " -i \(shellQuote(expandedPath))"
            }
            if let port, port != 22 { cmd += " -p \(port)" }
            cmd += user.isEmpty ? " \(host)" : " \(user)@\(host)"
            return password == nil ? cmd : nil // ssh no acepta password en el comando
        case "mysql":
            var cmd = "mysql"
            if !host.isEmpty { cmd += " -h \(host)" }
            if let port { cmd += " -P \(port)" }
            if !user.isEmpty { cmd += " -u \(user)" }
            if let escaped { cmd += " -p'\(escaped)'" } else { cmd += " -p" }
            if !db.isEmpty { cmd += " \(db)" }
            return cmd
        case "postgres":
            var cmd = ""
            if let escaped { cmd += "PGPASSWORD='\(escaped)' " }
            cmd += "psql"
            if !host.isEmpty { cmd += " -h \(host)" }
            if let port { cmd += " -p \(port)" }
            if !user.isEmpty { cmd += " -U \(user)" }
            if !db.isEmpty { cmd += " \(db)" }
            return cmd
        case "ftp", "ftpes", "ftps":
            var cmd = "ftp"
            cmd += user.isEmpty ? " \(host)" : " \(user)@\(host)"
            if let port, port != 21 { cmd += " \(port)" }
            return password == nil ? cmd : nil
        case "website":
            return details["url"].flatMap { $0.isEmpty ? nil : $0 }
        case "api":
            guard let url = details["url"], !url.isEmpty else { return nil }
            let auth = (details["auth"] ?? "none").lowercased()
            switch auth {
            case "bearer":
                let scheme = "Bearer"
                return "curl -H 'Authorization: \(scheme) $GDW_SECRET' '\(url)'"
            case "basic": return "curl -u '\(user):…' '\(url)'"
            case "header": return "curl -H '\(details["header_name"] ?? "Authorization"): …' '\(url)'"
            default: return "curl '\(url)'"
            }
        default:
            return nil
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
