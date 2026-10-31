import Foundation

enum TouchId {
    static var nextResult = true
    static var promptCount = 0

    static func authorizeSync(reason: String) -> Bool {
        promptCount += 1
        return nextResult
    }
}

final class Store {
    static let shared = Store()

    func applyPendingSecretUpdate(account: String) {}
}

@main
struct AuthSessionTests {
    static func main() {
        let session = AuthSession()
        let start = Date(timeIntervalSince1970: 1_000)

        precondition(session.authorizeSensitiveRead(account: "connection-1",
                                                    reason: "test", at: start))
        precondition(TouchId.promptCount == 1)
        precondition(session.authorizeSensitiveRead(account: "connection-1",
                                                    reason: "test", at: start.addingTimeInterval(899)))
        precondition(TouchId.promptCount == 1)
        precondition(session.cachedUses == 1)

        precondition(session.authorizeSensitiveRead(account: "connection-2",
                                                    reason: "test", at: start.addingTimeInterval(10)))
        precondition(TouchId.promptCount == 2)

        precondition(session.authorizeSensitiveRead(account: "connection-1",
                                                    reason: "test", at: start.addingTimeInterval(900)))
        precondition(TouchId.promptCount == 3)

        TouchId.nextResult = false
        precondition(!session.authorizeSensitiveRead(account: "connection-3",
                                                     reason: "test", at: start))
        precondition(!session.hasSensitiveReadAuthorization(account: "connection-3", at: start))
        print("Sensitive-read authorization tests passed")
    }
}
