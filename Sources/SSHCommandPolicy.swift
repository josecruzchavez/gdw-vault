import Foundation

enum SSHCommandTier: Equatable {
    case read
    case moderate
    case destructive
    case native
}

/// Clasificación genérica de comandos SSH. Solo una lista pequeña de comandos
/// se considera lectura; cualquier programa no reconocido o sintaxis de shell
/// compuesta se trata como ejecución nativa de código arbitrario.
enum SSHCommandPolicy {
    private static let shellSyntax = CharacterSet(charactersIn: ";|&<>`$()\\\n\r\"'!*?[]#")

    static func classify(_ command: String) -> SSHCommandTier {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .native }
        if trimmed.unicodeScalars.contains(where: shellSyntax.contains) {
            return .native
        }

        let lower = trimmed.lowercased()
        let first = lower.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let executable = first.split(separator: "/").last.map(String.init) ?? first

        let destructive: Set<String> = [
            "rm", "rmdir", "shred", "dd", "mkfs", "shutdown", "reboot", "halt",
            "poweroff", "init", "kill", "killall", "pkill", "userdel", "groupdel",
            "passwd", "visudo", "fdisk", "parted", "truncate", "chown", "chmod",
            "chgrp", "mv", "apt", "apt-get", "yum", "dnf", "pacman", "systemctl",
            "service", "scp", "rsync", "wget",
        ]
        if destructive.contains(executable) { return .destructive }

        // Cambios conocidos que se pueden autorizar en modo edición.
        if ["mkdir", "cp", "touch", "tee"].contains(executable) { return .moderate }

        let readOnly: Set<String> = [
            "ls", "cat", "head", "tail", "grep", "df", "du", "free", "uptime",
            "who", "whoami", "w", "ps", "uname", "hostname", "date", "echo",
            "pwd", "stat", "file", "wc", "sort", "uniq", "md5sum", "sha256sum",
            "which", "id", "groups", "last", "netstat", "ss", "ifconfig", "ip",
            "ping", "dig", "nslookup",
        ]
        if readOnly.contains(executable) { return .read }
        return .native
    }

    static func allowsNativeExecution(mode: String) -> Bool {
        mode == "unsafe"
    }
}
