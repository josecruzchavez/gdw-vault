import Foundation
import SQLite3

struct DatabaseStatement {
    let sql: String
    let params: [Any]
}

final class Store {
    static let shared = Store()
    private var db: OpaquePointer?
    private let databaseQueue = DispatchQueue(label: "mx.gdw.vault.sqlite")
    private let databaseQueueKey = DispatchSpecificKey<Void>()
    private let isDatabaseHost: Bool

    /// Notificado tras cualquier mutación (guardar/eliminar): el gancho de
    /// la sincronización automática.
    var onChange: (() -> Void)?

    private func notifyChange() {
        onChange?()
    }

    private init() {
        let commandArguments = Set(CommandLine.arguments.dropFirst())
        isDatabaseHost = commandArguments.isDisjoint(with: ["--mcp", "import", "exec", "list", "delete"])
        databaseQueue.setSpecific(key: databaseQueueKey, value: ())
        guard isDatabaseHost else { return }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GDWVault", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fatalError("No se pudo crear el directorio del vault: \(error.localizedDescription)")
        }
        let path = dir.appendingPathComponent("vault.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            fatalError("No se pudo abrir la base de datos: \(String(cString: sqlite3_errmsg(db)))")
        }
        let timeoutResult = sqlite3_busy_timeout(db, 5000)
        if timeoutResult != SQLITE_OK {
            NSLog("GDW Vault SQL error configuring busy timeout: %@", String(cString: sqlite3_errmsg(db)))
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA foreign_keys=ON;")
        migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL
        );
        CREATE TABLE IF NOT EXISTS connections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            group_id INTEGER NOT NULL REFERENCES groups(id),
            name TEXT NOT NULL,
            host TEXT,
            port INTEGER,
            protocol TEXT,
            username TEXT,
            keychain_account TEXT UNIQUE NOT NULL,
            notes TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now')),
            UNIQUE(group_id, name)
        );
        """)
        // v1.2: campos específicos por protocolo (JSON) en la columna details.
        if query("SELECT COUNT(*) AS n FROM pragma_table_info('connections') WHERE name='details'")
            .first?["n"] as? Int == 0 {
            exec("ALTER TABLE connections ADD COLUMN details TEXT")
        }
        // v1.4: llave de acceso asociada a la conexión (NULL = por password).
        if query("SELECT COUNT(*) AS n FROM pragma_table_info('connections') WHERE name='key_id'")
            .first?["n"] as? Int == 0 {
            exec("ALTER TABLE connections ADD COLUMN key_id INTEGER REFERENCES keys(id)")
        }
        // v1.5: fecha del último cambio de password (independiente de los
        // metadatos) para propagar cambios de secretos entre Macs sin pisar
        // un password local más nuevo.
        if query("SELECT COUNT(*) AS n FROM pragma_table_info('connections') WHERE name='secret_updated_at'")
            .first?["n"] as? Int == 0 {
            exec("ALTER TABLE connections ADD COLUMN secret_updated_at TEXT")
        }
        // v1.5: cuentas cuyo password llegó más nuevo por iCloud. Solo la
        // MARCA (nunca el valor): al usar la conexión se lee del snapshot
        // cifrado y se aplica. Visible desde GUI y MCP (procesos distintos).
        exec("""
        CREATE TABLE IF NOT EXISTS pending_secret_updates (
            keychain_account TEXT PRIMARY KEY,
            queued_at TEXT DEFAULT (datetime('now'))
        );
        """)
        // Sync: tumbas de conexiones eliminadas (para propagar borrados entre Macs).
        exec("""
        CREATE TABLE IF NOT EXISTS tombstones (
            keychain_account TEXT PRIMARY KEY,
            deleted_at TEXT DEFAULT (datetime('now'))
        );
        """)
        // v1.4: llaves de acceso SSH (ruta de llave pública y privada).
        exec("""
        CREATE TABLE IF NOT EXISTS keys (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL,
            pub_path TEXT,
            secret_path TEXT,
            notes TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        """)
    }

    func exec(_ sql: String) {
        guard isDatabaseHost else {
            _ = DatabaseIPCClient.shared.perform(operation: "exec", sql: sql)
            return
        }
        withDatabaseQueue { execLocal(sql) }
    }

    private func execLocal(_ sql: String) {
        _ = executeRawSQL(sql)
    }

    private func executeRawSQL(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &err)
        if result != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            NSLog("GDW Vault SQL error: \(message)")
        }
        sqlite3_free(err)
        return result == SQLITE_OK
    }

    private func withDatabaseQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: databaseQueueKey) != nil {
            return work()
        }
        return databaseQueue.sync(execute: work)
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [Any]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let s as String:
                sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let n as Int:
                sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64:
                sqlite3_bind_int64(stmt, idx, n)
            default:
                sqlite3_bind_null(stmt, idx)
            }
        }
    }

    func query(_ sql: String, _ params: [Any] = []) -> [[String: Any]] {
        guard isDatabaseHost else {
            return DatabaseIPCClient.shared.perform(operation: "query", sql: sql, params: params) as? [[String: Any]] ?? []
        }
        return withDatabaseQueue { queryLocal(sql, params) }
    }

    private func queryLocal(_ sql: String, _ params: [Any]) -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("GDW Vault SQL query error: %@", String(cString: sqlite3_errmsg(db)))
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)

        var rows: [[String: Any]] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            var row: [String: Any] = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER:
                    row[name] = Int(sqlite3_column_int64(stmt, col))
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(stmt, col))
                default:
                    row[name] = NSNull()
                }
            }
            rows.append(row)
            result = sqlite3_step(stmt)
        }
        if result != SQLITE_DONE {
            NSLog("GDW Vault SQL query error: %@", String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }

    func run(_ sql: String, _ params: [Any] = []) -> Bool {
        guard isDatabaseHost else {
            return DatabaseIPCClient.shared.perform(operation: "run", sql: sql, params: params) as? Bool ?? false
        }
        return withDatabaseQueue { runLocal(sql, params) }
    }

    private func runLocal(_ sql: String, _ params: [Any]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("GDW Vault SQL error: %@", String(cString: sqlite3_errmsg(db)))
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            NSLog("GDW Vault SQL error: %@", String(cString: sqlite3_errmsg(db)))
        }
        return result == SQLITE_DONE
    }

    func runTransaction(_ statements: [DatabaseStatement]) -> Bool {
        guard isDatabaseHost else {
            return DatabaseIPCClient.shared.perform(operation: "transaction", statements: statements) as? Bool ?? false
        }
        return performTransactionLocally(statements)
    }

    func performTransactionLocally(_ statements: [DatabaseStatement]) -> Bool {
        withDatabaseQueue {
            guard executeRawSQL("BEGIN IMMEDIATE;") else { return false }
            for statement in statements where !runLocal(statement.sql, statement.params) {
                _ = executeRawSQL("ROLLBACK;")
                return false
            }
            guard executeRawSQL("COMMIT;") else {
                _ = executeRawSQL("ROLLBACK;")
                return false
            }
            return true
        }
    }

    // MARK: - Groups

    func upsertGroup(_ name: String) -> Int {
        _ = run("INSERT OR IGNORE INTO groups(name) VALUES (?)", [name])
        return Int(query("SELECT id FROM groups WHERE name = ?", [name]).first?["id"] as? Int ?? 0)
    }

    @discardableResult
    func deleteGroup(id: Int) -> Bool {
        let ok = run("DELETE FROM groups WHERE id=?", [id])
        if ok { notifyChange() }
        return ok
    }

    func listGroups() -> [[String: Any]] {
        query("SELECT id, name FROM groups ORDER BY name COLLATE NOCASE")
    }

    // MARK: - Details por protocolo (JSON en la columna details)

    static func detailsJSON(_ details: [String: String]?) -> String? {
        guard let details, !details.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func detailsDict(from row: [String: Any]) -> [String: String] {
        guard let raw = row["details"] as? String, let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }

    // MARK: - Llaves de acceso

    @discardableResult
    func upsertKey(id: Int? = nil, name: String, pubPath: String?, secretPath: String?, notes: String?) -> Int {
        defer { notifyChange() }
        if let id {
            let ok = run("UPDATE keys SET name=?, pub_path=?, secret_path=?, notes=? WHERE id=?",
                         [name, pubPath.map { $0 as Any } ?? NSNull(), secretPath.map { $0 as Any } ?? NSNull(),
                          notes.map { $0 as Any } ?? NSNull(), id])
            return ok ? id : 0
        }
        _ = run("INSERT INTO keys(name, pub_path, secret_path, notes) VALUES (?,?,?,?)",
                [name, pubPath.map { $0 as Any } ?? NSNull(), secretPath.map { $0 as Any } ?? NSNull(),
                 notes.map { $0 as Any } ?? NSNull()])
        return Int(query("SELECT id FROM keys WHERE name=?", [name]).first?["id"] as? Int ?? 0)
    }

    func listKeys() -> [[String: Any]] {
        query("SELECT id, name, pub_path, secret_path, notes FROM keys ORDER BY name COLLATE NOCASE")
    }

    func findKey(id: Int) -> [String: Any]? {
        query("SELECT id, name, pub_path, secret_path, notes FROM keys WHERE id=?", [id]).first
    }

    func findKey(name: String) -> [String: Any]? {
        query("SELECT id, name, pub_path, secret_path, notes FROM keys WHERE name=? COLLATE NOCASE", [name]).first
    }

    // MARK: - Snapshot para sincronización por iCloud

    struct VaultSnapshot: Codable {
        var version = 4
        var exportedAt: String?
        var secret_key_id: String?
        var groups: [GroupSnap] = []
        var keys: [KeySnap] = []
        var connections: [ConnSnap] = []
        var tombstones: [TombstoneSnap]?
        /// Blobs de secretos cifrados: el primero es el más reciente
        /// (secretos usados en la ventana de gracia); los siguientes son
        /// heredados de exports anteriores (sin releer el Keychain).
        var secretBlobs: [SecretBlobSnap]?
        /// Legacy v2: un solo blob (se mantiene para decodificar snapshots viejos).
        var kdf: KdfSnap?
        var secretsBlob: String?
        struct GroupSnap: Codable { var name: String }
        struct KeySnap: Codable {
            var name: String
            var pub_path: String?
            var secret_path: String?
            var notes: String?
        }
        struct ConnSnap: Codable {
            var group: String
            var name: String
            var host: String?
            var port: Int?
            var `protocol`: String
            var username: String?
            var keychain_account: String
            var notes: String?
            var details: [String: String]?
            var key_name: String?
            var updated_at: String?
            /// Último cambio del password (no de los metadatos): permite a la
            /// Mac receptora saber si el secreto del snapshot es más nuevo
            /// que el local y marcarlo para actualizarse al usar la conexión.
            var secret_updated_at: String?
        }
        struct TombstoneSnap: Codable {
            var keychain_account: String
            var deleted_at: String
        }
        struct SecretBlobSnap: Codable {
            var kdf: KdfSnap
            var blob: String
            var exported_at: String?
            var key_id: String? = nil
        }
        struct KdfSnap: Codable {
            var salt: String
            var iterations: Int
        }
    }

    /// Snapshot de metadatos y blobs de secretos cifrados con la clave
    /// sincronizable del Keychain de iCloud.
    func exportSnapshot(syncKey: VaultSyncKey, previousData: Data? = nil) -> Data? {
        var snap = VaultSnapshot()
        snap.exportedAt = query("SELECT datetime('now') AS now").first?["now"] as? String
        snap.secret_key_id = syncKey.id
        for g in listGroups() {
            if let name = g["name"] as? String { snap.groups.append(.init(name: name)) }
        }
        for k in listKeys() {
            snap.keys.append(.init(name: k["name"] as? String ?? "",
                                   pub_path: k["pub_path"] as? String,
                                   secret_path: k["secret_path"] as? String,
                                   notes: k["notes"] as? String))
        }
        snap.tombstones = query("SELECT keychain_account, deleted_at FROM tombstones").compactMap { row in
            guard let acct = row["keychain_account"] as? String,
                  let deletedAt = row["deleted_at"] as? String else { return nil }
            return .init(keychain_account: acct, deleted_at: deletedAt)
        }
        if snap.tombstones?.isEmpty == true { snap.tombstones = nil }
        let rows = query("""
            SELECT c.*, g.name AS group_name FROM connections c
            JOIN groups g ON g.id = c.group_id
            ORDER BY g.name COLLATE NOCASE, c.name COLLATE NOCASE
            """)
        for c in rows {
            var keyName: String?
            if let keyId = c["key_id"] as? Int, let key = findKey(id: keyId) {
                keyName = key["name"] as? String
            }
            snap.connections.append(.init(
                group: c["group_name"] as? String ?? "",
                name: c["name"] as? String ?? "",
                host: c["host"] as? String,
                port: c["port"] as? Int,
                protocol: c["protocol"] as? String ?? "",
                username: c["username"] as? String,
                keychain_account: c["keychain_account"] as? String ?? "",
                notes: c["notes"] as? String,
                details: detailsDict(from: c).isEmpty ? nil : detailsDict(from: c),
                key_name: keyName,
                updated_at: c["updated_at"] as? String,
                secret_updated_at: c["secret_updated_at"] as? String))
        }
        // Secretos: SOLO los usados recientemente se releen del Keychain;
        // los demás viajan como blobs cifrados heredados del snapshot previo.
        var previousBlobs: [VaultSnapshot.SecretBlobSnap] = []
        if let previousData,
           let prevSnap = try? JSONDecoder().decode(VaultSnapshot.self, from: previousData) {
            previousBlobs = prevSnap.secretBlobs ?? []
            // Legacy v2: convertir el blob único a la lista.
            if previousBlobs.isEmpty, let kdf = prevSnap.kdf,
               let blob = prevSnap.secretsBlob {
                previousBlobs = [.init(kdf: kdf, blob: blob, exported_at: prevSnap.exportedAt)]
            }
        }

        var migratedSecrets: [String: String] = [:]
        var migratedBlobIndexes: Set<Int> = []
        for (index, blob) in previousBlobs.enumerated().reversed() {
            guard let keyID = blob.key_id else { continue }
            let material: String?
            if keyID == syncKey.id {
                material = syncKey.material
            } else {
                material = try? KeychainStore.shared.getSynchronizableVaultKey(id: keyID)
            }
            guard let material,
                  let combined = Data(base64Encoded: blob.blob),
                  let salt = Data(base64Encoded: blob.kdf.salt),
                  let plain = try? VaultCrypto.decrypt(combined, keyMaterial: material,
                                                       salt: salt, iterations: blob.kdf.iterations),
                  let secrets = try? JSONDecoder().decode([String: String].self, from: plain) else {
                continue
            }
            migratedBlobIndexes.insert(index)
            for (account, secret) in secrets where !account.isEmpty && !secret.isEmpty {
                migratedSecrets[account] = secret
            }
        }
        let blobsToKeep = previousBlobs.enumerated().compactMap { item in
            migratedBlobIndexes.contains(item.offset) ? nil : item.element
        }
        let recent = Set(AuthSession.shared.recentlyUsedAccounts())
        for c in rows {
            let account = c["keychain_account"] as? String ?? ""
            guard !account.isEmpty, recent.contains(account) else { continue }
            if let secret = KeychainStore.shared.getSecret(account: account), !secret.isEmpty {
                migratedSecrets[account] = secret
            }
        }

        var blobs = blobsToKeep
        if !migratedSecrets.isEmpty {
            guard let plain = try? JSONEncoder().encode(migratedSecrets),
                  let (enc, salt, iterations) = try? VaultCrypto.encrypt(
                    plain, keyMaterial: syncKey.material) else {
                return nil
            }
            blobs.insert(.init(kdf: .init(salt: salt.base64EncodedString(),
                                          iterations: iterations),
                               blob: enc.base64EncodedString(),
                               exported_at: snap.exportedAt,
                               key_id: syncKey.id), at: 0)
        }
        snap.secretBlobs = blobs.isEmpty ? nil : blobs

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(snap)
    }

    /// Importa un snapshot con fusión de metadatos y descifra los blobs que
    /// tienen una clave identificada y disponible en iCloud Keychain.
    /// Devuelve (nuevas, actualizadas, secretosRestaurados, eliminadas, localNuevas, error).
    func importSnapshot(_ data: Data, syncKey: VaultSyncKey) -> (added: Int, updated: Int, secretsRestored: Int, deleted: Int, localNewer: Int, error: String?) {
        guard let snap = try? JSONDecoder().decode(VaultSnapshot.self, from: data) else {
            return (0, 0, 0, 0, 0, "El snapshot no es un archivo válido de GDW Vault")
        }
        var added = 0, updated = 0, localNewer = 0
        // Cuentas cuyo password en el snapshot es más nuevo que el local:
        // su secreto se marca pendiente en lugar de sobreescribir el Keychain.
        var newerSecretAccounts: Set<String> = []
        for k in snap.keys {
            _ = upsertKey(name: k.name, pubPath: k.pub_path,
                          secretPath: k.secret_path, notes: k.notes)
        }
        for c in snap.connections {
            let gid = upsertGroup(c.group)
            let keyId = c.key_name.flatMap { findKey(name: $0)?["id"] as? Int }
            let local = query("SELECT id, updated_at, secret_updated_at FROM connections WHERE group_id=? AND name=?",
                              [gid, c.name]).first
            if let local {
                // Fusión: gana el más reciente por conexión.
                let localUpdated = local["updated_at"] as? String ?? ""
                let snapUpdated = c.updated_at ?? ""
                if snapUpdated > localUpdated {
                    _ = run("""
                        UPDATE connections SET host=?, port=?, protocol=?, username=?, notes=?, details=?, key_id=?, updated_at=?, secret_updated_at=COALESCE(?, secret_updated_at)
                        WHERE id=?
                        """, [c.host.map { $0 as Any } ?? NSNull(),
                              c.port.map { $0 as Any } ?? NSNull(),
                              c.protocol,
                              c.username.map { $0 as Any } ?? NSNull(),
                              c.notes.map { $0 as Any } ?? NSNull(),
                              Self.detailsJSON(c.details).map { $0 as Any } ?? NSNull(),
                              keyId.map { $0 as Any } ?? NSNull(),
                              snapUpdated,
                              c.secret_updated_at.map { $0 as Any } ?? NSNull(),
                              local["id"] as? Int ?? 0])
                    updated += 1
                    // El password del snapshot es más nuevo que el local:
                    // marcar su secreto para actualizarse al usar la conexión.
                    let snapSecret = c.secret_updated_at ?? ""
                    let localSecret = local["secret_updated_at"] as? String ?? ""
                    if !snapSecret.isEmpty, snapSecret > localSecret, !c.keychain_account.isEmpty {
                        newerSecretAccounts.insert(c.keychain_account)
                    }
                } else {
                    localNewer += 1
                }
            } else {
                let ok = run("""
                    INSERT INTO connections(group_id, name, host, port, protocol, username, keychain_account, notes, details, key_id, updated_at, secret_updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(group_id, name) DO UPDATE SET
                        host=excluded.host, port=excluded.port, protocol=excluded.protocol,
                        username=excluded.username, notes=excluded.notes, details=excluded.details,
                        key_id=excluded.key_id, updated_at=excluded.updated_at,
                        secret_updated_at=COALESCE(excluded.secret_updated_at, secret_updated_at)
                    """, [gid, c.name,
                          c.host.map { $0 as Any } ?? NSNull(),
                          c.port.map { $0 as Any } ?? NSNull(),
                          c.protocol,
                          c.username.map { $0 as Any } ?? NSNull(),
                          c.keychain_account,
                          c.notes.map { $0 as Any } ?? NSNull(),
                          Self.detailsJSON(c.details).map { $0 as Any } ?? NSNull(),
                          keyId.map { $0 as Any } ?? NSNull(),
                          (c.updated_at ?? "").isEmpty ? NSNull() : c.updated_at.map { $0 as Any } ?? NSNull(),
                          c.secret_updated_at.map { $0 as Any } ?? NSNull()])
                if ok { added += 1 }
            }
        }
        // Tumbas: propagar eliminaciones hechas en otra Mac.
        var deleted = 0
        for t in snap.tombstones ?? [] {
            let local = query("SELECT id, updated_at FROM connections WHERE keychain_account=?",
                              [t.keychain_account]).first
            guard let local,
                  let localUpdated = local["updated_at"] as? String else { continue }
            // Solo eliminar si la conexión local no fue modificada después del borrado.
            if localUpdated <= t.deleted_at {
                _ = run("DELETE FROM connections WHERE id=?", [local["id"] as? Int ?? 0])
                KeychainStore.shared.deleteSecret(account: t.keychain_account)
                clearPendingSecretUpdate(account: t.keychain_account)
                deleted += 1
            }
        }
        // Descifrar y fusionar TODOS los blobs (del más viejo al más nuevo,
        // para que el blob reciente gane). Cuentas sin secreto local: se
        // restaura directo. Cuentas con password más nuevo en el snapshot:
        // se marca pendiente para aplicarse al usar la conexión.
        var secretsRestored = 0
        var blobs: [(VaultSnapshot.KdfSnap, Data, String?)] = []
        for b in snap.secretBlobs ?? [] {
            if b.key_id != nil, let data = Data(base64Encoded: b.blob) {
                blobs.append((b.kdf, data, b.key_id))
            }
        }
        if !blobs.isEmpty {
            var missingKeyIDs: Set<String> = []
            var merged: [String: String] = [:]
            var failedBlobs = 0
            for (kdf, combined, keyID) in blobs.reversed() {
                guard let keyID else { continue }
                let material: String?
                if keyID == syncKey.id {
                    material = syncKey.material
                } else {
                    do {
                        material = try KeychainStore.shared.getSynchronizableVaultKey(id: keyID)
                    } catch {
                        return (added, updated, 0, deleted, localNewer,
                                error.localizedDescription)
                    }
                }
                if material == nil { missingKeyIDs.insert(keyID) }
                guard let material,
                      let salt = Data(base64Encoded: kdf.salt) else { continue }
                do {
                    let plain = try VaultCrypto.decrypt(combined, keyMaterial: material,
                                                        salt: salt, iterations: kdf.iterations)
                    let secrets = try JSONDecoder().decode([String: String].self, from: plain)
                    for (account, secret) in secrets where !account.isEmpty && !secret.isEmpty {
                        merged[account] = secret
                    }
                } catch {
                    failedBlobs += 1
                }
            }
            if !missingKeyIDs.isEmpty {
                return (added, updated, 0, deleted, localNewer,
                        "No están disponibles las claves de iCloud Keychain (\(missingKeyIDs.sorted().joined(separator: ", "))). Activa iCloud Keychain en esta Mac y vuelve a sincronizar.")
            }
            for (acct, secret) in merged {
                let hasConnection = query("SELECT id FROM connections WHERE keychain_account=?",
                                          [acct]).first != nil
                guard hasConnection else { continue }
                if !KeychainStore.shared.hasSecret(account: acct) {
                    if KeychainStore.shared.setSecret(account: acct, secret: secret) {
                        secretsRestored += 1
                    }
                } else if newerSecretAccounts.contains(acct) {
                    // Password cambiado en otra Mac: se marca para aplicarse
                    // al usar la conexión (sesión de 15 min), sin pisar el
                    // secreto local en la importación silenciosa.
                    queuePendingSecretUpdate(account: acct)
                }
            }
            if secretsRestored == 0, failedBlobs == blobs.count {
                return (added, updated, 0, deleted, localNewer,
                        "No se pudieron descifrar los secretos nuevos del snapshot. La clave no coincide o el archivo está dañado.")
            }
        }
        notifyChange()
        return (added, updated, secretsRestored, deleted, localNewer, nil)
    }

    func snapshotContainsLegacySecretBlobs(_ data: Data) -> Bool {
        guard let snap = try? JSONDecoder().decode(VaultSnapshot.self, from: data) else { return false }
        return (snap.secretBlobs ?? []).contains { $0.key_id == nil }
            || (snap.kdf != nil && snap.secretsBlob != nil)
    }

    /// Cuentas de Keychain de todas las conexiones (para migración a iCloud).
    func allKeychainAccounts() -> [String] {
        query("SELECT keychain_account FROM connections WHERE keychain_account IS NOT NULL")
            .compactMap { $0["keychain_account"] as? String }
    }

    @discardableResult
    func deleteKey(id: Int) -> Bool {
        // Las conexiones que la usaban quedan con key_id NULL (sin llave).
        let ok = runTransaction([
            DatabaseStatement(sql: "UPDATE connections SET key_id=NULL WHERE key_id=?", params: [id]),
            DatabaseStatement(sql: "DELETE FROM keys WHERE id=?", params: [id])
        ])
        if ok { notifyChange() }
        return ok
    }

    // MARK: - Connections

    @discardableResult
    func upsertConnection(groupId: Int, name: String, host: String?, port: Int?,
                          protocolType: String, username: String?, secret: String?, notes: String?,
                          details: [String: String]? = nil, keyId: Int? = nil) -> Int {
        let account = UUID().uuidString
        _ = run("""
            INSERT INTO connections(group_id, name, host, port, protocol, username, keychain_account, notes, details, key_id)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(group_id, name) DO UPDATE SET
                host=excluded.host, port=excluded.port, protocol=excluded.protocol,
                username=excluded.username, notes=excluded.notes, details=excluded.details,
                key_id=excluded.key_id, updated_at=datetime('now')
        """, [groupId, name, host.map { $0 as Any } ?? NSNull(), port.map { $0 as Any } ?? NSNull(),
              protocolType, username.map { $0 as Any } ?? NSNull(), account, notes.map { $0 as Any } ?? NSNull(),
              Self.detailsJSON(details).map { $0 as Any } ?? NSNull(), keyId.map { $0 as Any } ?? NSNull()])

        let row = query("SELECT id, keychain_account FROM connections WHERE group_id=? AND name=?", [groupId, name]).first
        guard let id = row?["id"] as? Int else { return 0 }
        let finalAccount = row?["keychain_account"] as? String ?? account
        if let secret, !secret.isEmpty {
            KeychainStore.shared.setSecret(account: finalAccount, secret: secret)
            _ = run("UPDATE connections SET secret_updated_at=datetime('now') WHERE id=?", [id])
            // El password local recién escrito es más nuevo que cualquier
            // pendiente de iCloud: se descarta antes de marcar el uso.
            clearPendingSecretUpdate(account: finalAccount)
            // Un password recién escrito debe viajar a las otras Macs.
            AuthSession.shared.markSecretUsed(account: finalAccount)
        }
        notifyChange()
        return id
    }

    // Actualiza por id conservando el keychain_account original (y su secreto).
    func updateConnection(id: Int, groupId: Int, name: String, host: String?, port: Int?,
                          protocolType: String, username: String?, secret: String?, notes: String?,
                          details: [String: String]? = nil, keyId: Int? = nil) -> Bool {
        guard let account = query("SELECT keychain_account FROM connections WHERE id=?", [id]).first?["keychain_account"] as? String else {
            return false
        }
        let ok = run("""
            UPDATE connections SET group_id=?, name=?, host=?, port=?, protocol=?, username=?, notes=?, details=?, key_id=?, updated_at=datetime('now')
            WHERE id=?
        """, [groupId, name, host.map { $0 as Any } ?? NSNull(), port.map { $0 as Any } ?? NSNull(),
              protocolType, username.map { $0 as Any } ?? NSNull(), notes.map { $0 as Any } ?? NSNull(),
              Self.detailsJSON(details).map { $0 as Any } ?? NSNull(), keyId.map { $0 as Any } ?? NSNull(), id])
        if ok, let secret, !secret.isEmpty {
            KeychainStore.shared.setSecret(account: account, secret: secret)
            _ = run("UPDATE connections SET secret_updated_at=datetime('now') WHERE id=?", [id])
            // El password local recién escrito es más nuevo que cualquier
            // pendiente de iCloud: se descarta antes de marcar el uso.
            clearPendingSecretUpdate(account: account)
            // Un password recién escrito debe viajar a las otras Macs.
            AuthSession.shared.markSecretUsed(account: account)
        }
        if ok { notifyChange() }
        return ok
    }

    // Borra la conexión y su secreto del Keychain; deja una tumba para que
    // la eliminación se propague a las otras Macs en la sincronización.
    @discardableResult
    func deleteConnection(id: Int) -> Bool {
        guard let account = query("SELECT keychain_account FROM connections WHERE id=?", [id]).first?["keychain_account"] as? String else {
            return false
        }
        guard runTransaction([
            DatabaseStatement(sql: "DELETE FROM connections WHERE id=?", params: [id]),
            DatabaseStatement(sql: "INSERT OR REPLACE INTO tombstones(keychain_account, deleted_at) VALUES (?, datetime('now'))",
                              params: [account])
        ]) else { return false }
        KeychainStore.shared.deleteSecret(account: account)
        clearPendingSecretUpdate(account: account)
        notifyChange()
        return true
    }

    func listConnections(groupId: Int? = nil) -> [[String: Any]] {
        if let groupId {
            return query("""
                SELECT c.id, c.name, c.host, c.port, c.protocol, c.username, c.details, c.key_id, g.name AS group_name
                FROM connections c JOIN groups g ON g.id = c.group_id
                WHERE c.group_id = ? ORDER BY c.name COLLATE NOCASE
            """, [groupId])
        }
        return query("""
            SELECT c.id, c.name, c.host, c.port, c.protocol, c.username, c.details, c.key_id, g.name AS group_name
            FROM connections c JOIN groups g ON g.id = c.group_id
            ORDER BY g.name COLLATE NOCASE, c.name COLLATE NOCASE
        """)
    }

    func findConnection(id: Int? = nil, name: String? = nil) -> [String: Any]? {
        if let id {
            return query("SELECT c.*, g.name AS group_name FROM connections c JOIN groups g ON g.id=c.group_id WHERE c.id=?", [id]).first
        }
        if let name {
            return query("SELECT c.*, g.name AS group_name FROM connections c JOIN groups g ON g.id=c.group_id WHERE c.name=? COLLATE NOCASE", [name]).first
        }
        return nil
    }

    @discardableResult
    func setSensitiveFileReadAccess(connectionId: Int, enabled: Bool) -> Bool {
        guard let connection = findConnection(id: connectionId),
              let protocolType = connection["protocol"] as? String,
              ["ssh", "sftp"].contains(protocolType.lowercased()) else { return false }

        let details = detailsDict(from: connection)
        guard SensitiveFilePolicy.isEnabled(in: details) != enabled else { return true }

        let settingPath = "$.\(SensitiveFilePolicy.connectionSetting)"
        let sql: String
        let params: [Any]
        if enabled {
            sql = """
            UPDATE connections
            SET details=json_set(COALESCE(details, '{}'), ?, 'true'),
                updated_at=datetime('now')
            WHERE id=? AND lower(protocol) IN ('ssh', 'sftp')
            """
            params = [settingPath, connectionId]
        } else {
            sql = """
            UPDATE connections
            SET details=NULLIF(json_remove(COALESCE(details, '{}'), ?), '{}'),
                updated_at=datetime('now')
            WHERE id=? AND lower(protocol) IN ('ssh', 'sftp')
            """
            params = [settingPath, connectionId]
        }

        let ok = run(sql, params)
        if ok { notifyChange() }
        return ok
    }

    // MARK: - Passwords pendientes de sincronización

    /// Marca una cuenta cuyo password llegó más nuevo por iCloud: se aplica
    /// al USAR la conexión (sesión de 15 min), no en la importación silenciosa.
    func queuePendingSecretUpdate(account: String) {
        guard !account.isEmpty else { return }
        _ = run("INSERT OR REPLACE INTO pending_secret_updates(keychain_account, queued_at) VALUES (?, datetime('now'))",
                [account])
    }

    func hasPendingSecretUpdate(account: String) -> Bool {
        query("SELECT 1 FROM pending_secret_updates WHERE keychain_account=?", [account]).first != nil
    }

    func clearPendingSecretUpdate(account: String) {
        _ = run("DELETE FROM pending_secret_updates WHERE keychain_account=?", [account])
    }

    func secretFor(connection: [String: Any]) -> String? {
        guard let account = connection["keychain_account"] as? String else { return nil }
        return KeychainStore.shared.getSecret(account: account)
    }
}
