import Foundation

/// Thin async client for the Mac-side watch bridge. One blocking POST per
/// chat turn; the bridge enforces single-turn serialization and returns 202
/// with partial=true if its reply budget expires while Claude is still
/// working (fetch /last afterwards for the finished reply).
struct BridgeClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 150
        return URLSession(configuration: config)
    }()

    func chat(_ message: String) async throws -> ChatResponse {
        try await request(path: "/chat", method: "POST", body: ["message": message])
    }

    func last() async throws -> ChatResponse {
        try await request(path: "/last", method: "GET", body: nil)
    }

    func reset() async throws -> ChatResponse {
        try await request(path: "/reset", method: "POST", body: nil)
    }

    /// Fire-and-forget slash command (/model, /effort). The bridge types it
    /// into the interactive session without waiting for an assistant turn.
    func command(_ command: String) async throws -> ChatResponse {
        try await request(path: "/command", method: "POST", body: ["command": command])
    }

    private func request(path: String, method: String, body: [String: String]?) async throws -> ChatResponse {
        guard let url = BridgeConfig.url(path) else { throw BridgeError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await Self.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = (try? JSONDecoder().decode(ChatResponse.self, from: data)) ?? ChatResponse()
        switch status {
        case 200, 202:
            return decoded
        case 401:
            throw BridgeError.unauthorized
        case 409:
            throw BridgeError.turnInFlight
        case 503:
            throw BridgeError.notReady
        default:
            throw BridgeError.server(decoded.error ?? "Bridge error (HTTP \(status))")
        }
    }
}
