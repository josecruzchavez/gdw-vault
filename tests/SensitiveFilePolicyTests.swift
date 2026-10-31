@main
struct SensitiveFilePolicyTests {
    static func main() {
        let protectedCommands: [(String, String)] = [
            ("cat /srv/site/.env", ".env"),
            ("cat /srv/site/.env.production.local", ".env.production.local"),
            ("cat .e\"\"nv", ".env"),
            ("cat .e\\nv", ".env"),
            ("php app/etc/env.php", "env.php"),
            ("grep password app/etc/local.xml", "local.xml"),
            ("cat /var/www/wp-config.php.bak", "wp-config.php.bak"),
            ("cat wp-''config.php", "wp-config.php"),
            ("cat configuration.php", "configuration.php"),
            ("cat sites/default/settings.php", "settings.php"),
            ("cat typo3conf/LocalConfiguration.php", "LocalConfiguration.php"),
            ("cat app/config/parameters.php", "parameters.php"),
            ("cat app/config/parameters.yml", "parameters.yml"),
            ("cat config/app_local.php", "app_local.php"),
            ("cat app/Config/Database.php", "Database.php"),
            ("cat config/master.key", "master.key"),
            ("cat config/credentials.yml.enc", "credentials.yml.enc"),
            ("cat config/secrets/prod.decrypt.private.php", "decrypt.private.php"),
            ("cat bootstrap/cache/config.php", "bootstrap/cache/config.php"),
            ("cat application-prod.properties", "application-prod.properties"),
            ("cat application-staging.yaml", "application-staging.yaml"),
            ("cat appsettings.Production.json", "appsettings.Production.json"),
            ("cat config.production.json", "config.production.json"),
        ]
        for (command, expected) in protectedCommands {
            precondition(SensitiveFilePolicy.matchedName(in: command) == expected, command)
        }

        let privateKeyCommands: [(String, String)] = [
            ("cat /home/deploy/.ssh/id_rsa", "id_rsa"),
            ("cat ~/.ssh/id_ed25519", "id_ed25519"),
            ("cat '~/.ssh/id_ecdsa_sk'", "id_ecdsa_sk"),
            ("cat /etc/ssh/ssh_host_ed25519_key", "ssh_host_ed25519_key"),
            ("cat /tmp/deploy.pem", "deploy.pem"),
            ("cat /tmp/server.key", "server.key"),
            ("cat /tmp/client.p12", "client.p12"),
        ]
        for (command, expected) in privateKeyCommands {
            precondition(SensitiveFilePolicy.matchedPrivateKeyName(in: command) == expected, command)
        }

        precondition(SensitiveFilePolicy.matchedName(in: "ls -la /var/www") == nil)
        precondition(SensitiveFilePolicy.matchedName(in: "cat .environment") == nil)
        precondition(SensitiveFilePolicy.matchedName(in: "cat generic/config.php") == nil)
        precondition(SensitiveFilePolicy.matchedPrivateKeyName(in: "cat ~/.ssh/id_ed25519.pub") == nil)
        precondition(SensitiveFilePolicy.matchedPrivateKeyName(in: "cat ~/.ssh/authorized_keys") == nil)
        precondition(!SensitiveFilePolicy.isEnabled(in: [:]))
        precondition(SensitiveFilePolicy.isEnabled(in: [
            SensitiveFilePolicy.connectionSetting: "true"
        ]))
        precondition(!SensitiveFilePolicy.isEnabled(in: [
            SensitiveFilePolicy.connectionSetting: "false"
        ]))
        print("Sensitive file policy tests passed")
    }
}
