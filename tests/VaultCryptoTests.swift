import Foundation

@main
struct VaultCryptoTests {
    static func main() throws {
        let payload = Data(#"{"account":"secret"}"#.utf8)
        let generatedKey = try VaultCrypto.generateRandomKeyMaterial()
        let secondGeneratedKey = try VaultCrypto.generateRandomKeyMaterial()
        precondition(Data(base64Encoded: generatedKey)?.count == 32)
        precondition(generatedKey != secondGeneratedKey)

        let current = try VaultCrypto.encrypt(payload, keyMaterial: generatedKey)
        let currentPlain = try VaultCrypto.decrypt(
            current.data, keyMaterial: generatedKey,
            salt: current.salt, iterations: current.iterations)
        precondition(currentPlain == payload)

        print("Vault crypto tests passed")
    }
}
