import Foundation

enum SensitiveFilePolicy {
    static let connectionSetting = "allow_sensitive_file_reads"
    private static let protectedFilenamePattern = try? NSRegularExpression(
        pattern: #"(?:^|[^A-Za-z0-9_])((?:\.env(?:\.[A-Za-z0-9_-]+)*|wp-config\.php|env\.php|local\.xml|configuration\.php|settings\.php|LocalConfiguration\.php|parameters\.(?:php|yml)|app_local\.php|Database\.php|master\.key|credentials\.yml\.enc|decrypt\.private\.php|bootstrap/cache/config\.php|application[^/\s"'`]*\.(?:properties|ya?ml)|appsettings[^/\s"'`]*\.json|config\.(?:production|staging|development)\.json)(?:\.[A-Za-z0-9_-]+)*)(?=$|[^A-Za-z0-9_])"#,
        options: [.caseInsensitive])
    private static let privateKeyFilenamePattern = try? NSRegularExpression(
        pattern: #"(?:^|[^A-Za-z0-9_])((?:id_(?:rsa|dsa|ecdsa|ed25519)(?:_sk)?(?!\.pub)|ssh_host_(?:rsa|dsa|ecdsa|ed25519)_key|[^/\s"'`]+\.(?:pem|key|p12|pfx|ppk)))(?=$|[^A-Za-z0-9_])"#,
        options: [.caseInsensitive])

    static func matchedName(in command: String) -> String? {
        matchedName(in: command, pattern: protectedFilenamePattern)
    }

    static func matchedPrivateKeyName(in command: String) -> String? {
        matchedName(in: command, pattern: privateKeyFilenamePattern)
    }

    private static func matchedName(in command: String,
                                    pattern: NSRegularExpression?) -> String? {
        let normalizedCommand = removingShellQuoteSyntax(from: command)
        guard let pattern,
              let match = pattern.firstMatch(
                in: normalizedCommand,
                range: NSRange(normalizedCommand.startIndex..., in: normalizedCommand)),
              let range = Range(match.range(at: 1), in: normalizedCommand) else { return nil }
        return String(normalizedCommand[range])
    }

    static func isEnabled(in details: [String: String]) -> Bool {
        details[connectionSetting] == "true"
    }

    private static func removingShellQuoteSyntax(from command: String) -> String {
        var normalized = ""
        var quote: Character?
        var escaping = false

        for character in command {
            if escaping {
                normalized.append(character)
                escaping = false
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == "\\" && activeQuote != "'" {
                    escaping = true
                } else {
                    normalized.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character == "\\" {
                escaping = true
            } else {
                normalized.append(character)
            }
        }
        if escaping { normalized.append("\\") }
        return normalized
    }
}
