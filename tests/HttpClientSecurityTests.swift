import Foundation

@main
struct HttpClientSecurityTests {
    static func main() {
        let configuredURL = URL(string: "https://api.example.test/v1")!
        precondition(HttpClient.hasSameOrigin(
            URL(string: "https://api.example.test:443/v2/items")!,
            as: configuredURL))
        precondition(!HttpClient.hasSameOrigin(
            URL(string: "https://other.example.test/v1")!,
            as: configuredURL))
        precondition(!HttpClient.hasSameOrigin(
            URL(string: "http://api.example.test/v1")!,
            as: configuredURL))
        precondition(!HttpClient.hasSameOrigin(
            URL(string: "https://api.example.test:8443/v1")!,
            as: configuredURL))

        let url = URL(string:
            "https://user:password@api.example.test/v1/items?token=hidden&limit=5#details")!
        precondition(HttpClient.sanitizedURL(url) == "https://api.example.test/v1/items")
        print("HTTP client security tests passed")
    }
}
