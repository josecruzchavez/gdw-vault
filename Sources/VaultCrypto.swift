import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Cifrado de secretos para el snapshot de iCloud: AES-256-GCM con clave
/// derivada por PBKDF2-SHA256 del material aleatorio sincronizable del Keychain.
enum VaultCrypto {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func generateRandomKeyMaterial() throws -> String {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw Failure(message: "No se pudo generar la clave de sincronización")
        }
        return bytes.base64EncodedString()
    }

    static func deriveKey(keyMaterial: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordData = Data(keyMaterial.utf8)
        var derived = Data(repeating: 0, count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { pwdBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwdBytes.baseAddress, passwordData.count,
                        saltBytes.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress, 32)
                }
            }
        }
        guard status == kCCSuccess else {
            throw Failure(message: "No se pudo derivar la clave (PBKDF2)")
        }
        return SymmetricKey(data: derived)
    }

    /// Cifra y devuelve (datos combinados nonce+ct+tag, salt, iteraciones).
    static func encrypt(_ plaintext: Data, keyMaterial: String) throws -> (data: Data, salt: Data, iterations: Int) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let iterations = 200_000
        let key = try deriveKey(keyMaterial: keyMaterial, salt: salt, iterations: iterations)
        guard let combined = try? AES.GCM.seal(plaintext, using: key).combined else {
            throw Failure(message: "No se pudo cifrar el snapshot")
        }
        return (combined, salt, iterations)
    }

    /// Descifra; lanza authenticationFailure si el material de clave no coincide.
    static func decrypt(_ combined: Data, keyMaterial: String, salt: Data, iterations: Int) throws -> Data {
        let key = try deriveKey(keyMaterial: keyMaterial, salt: salt, iterations: iterations)
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }
}
