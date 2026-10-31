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

        precondition(SensitiveFilePolicy.matchedName(in: "ls -la /var/www") == nil)
        precondition(SensitiveFilePolicy.matchedName(in: "cat .environment") == nil)
        precondition(SensitiveFilePolicy.matchedName(in: "cat generic/config.php") == nil)
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
