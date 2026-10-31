import Foundation
import LocalAuthentication

/// Caché de autorización Touch ID para reducir la frecuencia de prompts.
/// Tras un Touch ID exitoso, las llamadas siguientes dentro de la ventana de
/// gracia (15 min) no vuelven a pedirlo. El contador permite auditar cuántos
/// prompts se pidieron y cuántos se ahorraron en la sesión del servidor MCP.
final class AuthSession {
    static let shared = AuthSession()

    private(set) var prompts = 0
    private(set) var cachedUses = 0
    private(set) var denials = 0
    private var lastAuth: Date?
    private var sensitiveReadAuthorizations: [String: Date] = [:]

    /// Secretos usados recientemente por acciones del usuario: la ventana de
    /// gracia de 15 min define qué secretos se re-sincronizan a iCloud.
    private var secretUsage: [String: Date] = [:]

    /// Registra el uso reciente de un secreto para una posible exportación cifrada.
    func markSecretUsed(account: String) {
        secretUsage[account] = Date()
    }

    /// Cuentas con secreto usado dentro de la ventana de gracia.
    func recentlyUsedAccounts() -> [String] {
        let cutoff = Date().addingTimeInterval(-window)
        return secretUsage.filter { $0.value > cutoff }.map { $0.key }
    }

    /// Ventana de gracia para consultas de solo lectura.
    let window: TimeInterval = 900

    var isValid: Bool {
        guard let lastAuth else { return false }
        return Date().timeIntervalSince(lastAuth) < window
    }

    /// Pide Touch ID solo si la caché expiró. Devuelve true si hay autorización.
    @discardableResult
    func authorize(reason: String) -> Bool {
        if isValid {
            cachedUses += 1
            return true
        }
        return forceAuthorize(reason: reason)
    }

    /// Autoriza lecturas sensibles con una ventana independiente por conexión.
    /// No reutiliza la autorización de una lectura normal para elevar permisos.
    @discardableResult
    func authorizeSensitiveRead(account: String, reason: String, at now: Date = Date()) -> Bool {
        if !account.isEmpty,
           hasSensitiveReadAuthorization(account: account, at: now) {
            cachedUses += 1
            return true
        }
        guard forceAuthorize(reason: reason) else { return false }
        if !account.isEmpty {
            let expiredAccounts = sensitiveReadAuthorizations.compactMap { account, authorizedAt in
                let elapsed = now.timeIntervalSince(authorizedAt)
                return elapsed < 0 || elapsed >= window ? account : nil
            }
            for expiredAccount in expiredAccounts {
                sensitiveReadAuthorizations.removeValue(forKey: expiredAccount)
            }
            sensitiveReadAuthorizations[account] = now
        }
        return true
    }

    func hasSensitiveReadAuthorization(account: String, at now: Date = Date()) -> Bool {
        guard !account.isEmpty,
              let authorizedAt = sensitiveReadAuthorizations[account] else { return false }
        let elapsed = now.timeIntervalSince(authorizedAt)
        return elapsed >= 0 && elapsed < window
    }

    /// Siempre pide Touch ID (operaciones destructivas) y refresca la ventana.
    @discardableResult
    func forceAuthorize(reason: String) -> Bool {
        let granted = TouchId.authorizeSync(reason: reason)
        if granted {
            prompts += 1
            lastAuth = Date()
        } else {
            denials += 1
        }
        return granted
    }

    func reset() {
        prompts = 0
        cachedUses = 0
        denials = 0
        lastAuth = nil
        sensitiveReadAuthorizations.removeAll()
    }

    /// Resumen de auditoría para incluir en las respuestas del MCP.
    func statsDescription() -> String {
        if prompts == 0 && cachedUses == 0 {
            return "sin prompts esta sesión"
        }
        var parts = ["Touch ID pedido \(prompts) \(prompts == 1 ? "vez" : "veces")"]
        if cachedUses > 0 {
            parts.append("\(cachedUses) llamadas reutilizaron la autorización (ventana \(Int(window / 60)) min)")
        }
        if denials > 0 {
            parts.append("\(denials) rechazos")
        }
        return parts.joined(separator: ", ")
    }
}
