import Foundation

/// Utilidades para no reventar el contexto del chat ni filtrar secretos al
/// devolver la salida de comandos y respuestas HTTP.
enum OutputText {
    static let defaultLimit = 20_000

    /// Recorta salidas largas indicando cuánto se omitió.
    static func truncate(_ text: String, limit: Int = defaultLimit) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end])
            + "\n… (salida recortada: \(text.count) caracteres en total; usa grep/head para acotar)"
    }

    /// Reemplaza cualquier aparición literal de un secreto en la salida.
    /// Ignora cadenas muy cortas para no destrozar el texto.
    static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "•••")
        }
        return result
    }
}
