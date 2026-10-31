import Foundation
import LocalAuthentication

enum TouchId {
    /// Pide Touch ID (o password del equipo como fallback) antes de ejecutar una acción sensible.
    static func authorize(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                completion(success)
            }
        } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                completion(success)
            }
        } else {
            // Sin biometría ni password configurado: rechazar (equipo sin protección).
            completion(false)
        }
    }

    static func authorizeSync(reason: String, timeout: TimeInterval = 60) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        authorize(reason: reason) { success in
            granted = success
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return granted
    }
}
