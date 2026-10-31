import Darwin
import Foundation

enum StatusInstanceLock {
    private static var descriptor: Int32 = -1

    static func acquire() -> Bool {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GDWVault", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("GDW Vault: no se pudo preparar el directorio de instancia: %@", error.localizedDescription)
            return false
        }

        let path = directory.appendingPathComponent("status-ui.lock").path
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            NSLog("GDW Vault: no se pudo abrir el bloqueo de instancia (errno %d)", errno)
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }
}
