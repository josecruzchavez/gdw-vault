@main
struct SSHCommandPolicyTests {
    static func main() {
        precondition(SSHCommandPolicy.classify("hostname") == .read)
        precondition(SSHCommandPolicy.classify("/usr/bin/ls -la /srv/site") == .read)
        precondition(SSHCommandPolicy.classify("git status") == .native)
        precondition(SSHCommandPolicy.classify("mkdir -p /tmp/inv") == .moderate)
        precondition(SSHCommandPolicy.classify("rm -rf /tmp/inv") == .destructive)

        precondition(SSHCommandPolicy.classify("php -r 'echo 1;'") == .native)
        precondition(SSHCommandPolicy.classify("python3 -c print(1)") == .native)
        precondition(SSHCommandPolicy.classify("bin/magento cache:flush") == .native)
        precondition(SSHCommandPolicy.classify("mysql -e SELECT") == .native)
        precondition(SSHCommandPolicy.classify("ls && php -r print(1)") == .native)
        precondition(SSHCommandPolicy.classify("unknown-command --version") == .native)

        precondition(SSHCommandPolicy.allowsNativeExecution(mode: "unsafe"))
        precondition(!SSHCommandPolicy.allowsNativeExecution(mode: "edicion"))
        precondition(!SSHCommandPolicy.allowsNativeExecution(mode: "lectura"))

        let stressCases: [(String, SSHCommandTier)] = [
            ("hostname", .read),
            ("mkdir -p /tmp/inv", .moderate),
            ("rm -rf /tmp/inv", .destructive),
            ("php -r 'echo 1;'", .native),
            ("bin/magento cache:flush", .native),
            ("ls && php -r print(1)", .native),
        ]
        for _ in 0..<10_000 {
            for (command, expected) in stressCases {
                precondition(SSHCommandPolicy.classify(command) == expected)
            }
        }

        print("SSH command policy tests passed (60,000 classifications)")
    }
}
