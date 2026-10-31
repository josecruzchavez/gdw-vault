import Foundation
import Security

struct VaultSyncKey {
    let id: String
    let material: String
}

final class KeychainStore {
    static let shared = KeychainStore()
    private let service = "mx.gdw.vault"
    private let syncKeyAccountPrefix = "icloud-vault-key-"
    private let activeSyncKeyIDAccount = "icloud-vault-active-key-id"

    enum SyncKeyError: LocalizedError {
        case keychain(OSStatus)
        case randomKey(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "Keychain rechazó la clave de sincronización (código \(status))."
            case .randomKey(let message):
                return message
            case .unavailable(let id):
                return "La clave de iCloud Keychain \(id) aún no está disponible en esta Mac. Comprueba que iCloud Keychain esté activado y vuelve a sincronizar."
            }
        }
    }

    /// Guarda el secreto. Devuelve false si el Keychain rechazó la escritura
    /// (antes fallaba en silencio y las conexiones quedaban sin password).
    @discardableResult
    func setSecret(account: String, secret: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = Data(secret.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    func getSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Verifica si hay un secreto guardado sin leer su contenido (no pide Touch ID).
    func hasSecret(account: String) -> Bool {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        return status == errSecSuccess
    }

    func deleteSecret(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    func getSynchronizableVaultKey(id: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: syncKeyAccountPrefix + id,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let material = String(data: data, encoding: .utf8) else {
            throw SyncKeyError.keychain(status)
        }
        return material
    }

    func getOrCreateSynchronizableVaultKey() throws -> VaultSyncKey {
        if let id = getSecret(account: activeSyncKeyIDAccount) {
            guard let material = try getSynchronizableVaultKey(id: id) else {
                throw SyncKeyError.unavailable(id)
            }
            return VaultSyncKey(id: id, material: material)
        }

        let id = UUID().uuidString
        let material: String
        do {
            material = try VaultCrypto.generateRandomKeyMaterial()
        } catch {
            throw SyncKeyError.randomKey(error.localizedDescription)
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: syncKeyAccountPrefix + id,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String: Data(material.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SyncKeyError.keychain(status)
        }
        guard setSecret(account: activeSyncKeyIDAccount, secret: id) else {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: syncKeyAccountPrefix + id,
                kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            ] as CFDictionary)
            throw SyncKeyError.keychain(errSecNotAvailable)
        }
        return VaultSyncKey(id: id, material: material)
    }
}
