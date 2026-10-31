import Foundation
import AppKit

/// Implementación anterior de sincronización por snapshot, conservada para
/// referencia. No está conectada al ciclo local de la app ni de los procesos MCP.
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    private let store = Store.shared
    private var workItem: DispatchWorkItem?
    private var busy = false

    var snapshotURL: URL? {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/GDWVault/vault-snapshot.json")
    }

    /// Llamar al lanzar la app: importa (fusión) y exporta si hubo cambios
    /// locales más nuevos que el snapshot.
    func syncOnLaunch() {
        guard !busy, let url = snapshotURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let error = exportNow() {
                NSLog("GDW Vault: iCloud sync failed: %@", error)
            }
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let key = try syncKey(for: data)
            let hasLegacySecrets = store.snapshotContainsLegacySecretBlobs(data)
            let result = store.importSnapshot(data, syncKey: key)
            if let error = result.error {
                NSLog("GDW Vault: iCloud sync failed: %@", error)
            } else if hasLegacySecrets {
                NSLog("GDW Vault: legacy encrypted secrets were skipped; they cannot be imported by this version")
            } else if result.localNewer > 0 || result.added > 0 {
                if let error = exportNow() {
                    NSLog("GDW Vault: iCloud sync failed: %@", error)
                }
            }
        } catch {
            NSLog("GDW Vault: iCloud sync failed: %@", error.localizedDescription)
        }
    }

    /// Programa una exportación con debounce (gancho de Store.onChange).
    func scheduleExport() {
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            if let error = self?.exportNow() {
                NSLog("GDW Vault: iCloud export failed: %@", error)
            }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// Importa (fusión) y exporta en un solo paso.
    @discardableResult
    func syncNow() -> (added: Int, updated: Int, deleted: Int, secretsRestored: Int, localNewer: Int, warning: String?, error: String?) {
        guard !busy, let url = snapshotURL else {
            return (0, 0, 0, 0, 0, nil, "iCloud Drive no disponible")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let key = try syncKey(for: data)
                let hasLegacySecrets = store.snapshotContainsLegacySecretBlobs(data)
                let result = store.importSnapshot(data, syncKey: key)
                if let error = result.error {
                    return (result.added, result.updated, result.deleted,
                            result.secretsRestored, result.localNewer, nil, error)
                }
                if let error = exportNow() {
                    return (result.added, result.updated, result.deleted,
                            result.secretsRestored, result.localNewer, nil, error)
                }
                return (result.added, result.updated, result.deleted,
                        result.secretsRestored, result.localNewer,
                        hasLegacySecrets
                            ? "El snapshot conserva secretos cifrados con el método anterior; no se importaron."
                            : nil,
                        nil)
            } catch {
                return (0, 0, 0, 0, 0, nil, error.localizedDescription)
            }
        }
        if let error = exportNow() {
            return (0, 0, 0, 0, 0, nil, error)
        }
        return (0, 0, 0, 0, 0, nil, nil)
    }

    @discardableResult
    func exportNow() -> String? {
        guard !busy, let url = snapshotURL else {
            return "iCloud Drive no disponible o sincronización ocupada"
        }
        busy = true
        defer { busy = false }
        do {
            let previous: Data?
            if FileManager.default.fileExists(atPath: url.path) {
                previous = try Data(contentsOf: url)
            } else {
                previous = nil
            }
            let key = try syncKey(for: previous)
            guard let data = store.exportSnapshot(
                syncKey: key,
                previousData: previous) else {
                return "No se pudo construir el snapshot de iCloud"
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func syncKey(for data: Data?) throws -> VaultSyncKey {
        if let data,
           let snapshot = try? JSONDecoder().decode(Store.VaultSnapshot.self, from: data),
           let keyID = snapshot.secret_key_id {
            guard let material = try KeychainStore.shared.getSynchronizableVaultKey(id: keyID) else {
                throw KeychainStore.SyncKeyError.unavailable(keyID)
            }
            return VaultSyncKey(id: keyID, material: material)
        }
        return try KeychainStore.shared.getOrCreateSynchronizableVaultKey()
    }
}
