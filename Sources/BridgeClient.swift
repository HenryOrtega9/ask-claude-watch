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

    func sessions() async throws -> [BridgeSession] {
        let response: SessionsResponse = try await getJSON("/sessions")
        return response.sessions
    }

    func sessionMessages(id: String, limit: Int = 40) async throws -> SessionMessagesResponse {
        try await getJSON("/sessions/\(id)/messages?limit=\(limit)")
    }

    /// Fire-and-forget inject into any attachable session; poll
    /// sessionMessages for the reply.
    func sessionSend(id: String, message: String) async throws {
        let (data, status) = try await raw(
            path: "/sessions/\(id)/send", method: "POST", body: ["message": message]
        )
        guard status == 200 else { throw Self.error(for: status, data: data) }
    }

    func usage() async throws -> UsageResponse {
        try await getJSON("/usage")
    }

    private func request(path: String, method: String, body: [String: String]?) async throws -> ChatResponse {
        let (data, status) = try await raw(path: path, method: method, body: body)
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

    private func getJSON<T: Decodable>(_ path: String) async throws -> T {
        let (data, status) = try await raw(path: path, method: "GET", body: nil)
        guard status == 200 else { throw Self.error(for: status, data: data) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func raw(path: String, method: String, body: [String: String]?) async throws -> (Data, Int) {
        guard let url = BridgeConfig.url(path) else { throw BridgeError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await Self.session.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func error(for status: Int, data: Data) -> BridgeError {
        if status == 401 { return .unauthorized }
        let message = (try? JSONDecoder().decode(ChatResponse.self, from: data))?.error
        return .server(message ?? "Bridge error (HTTP \(status))")
    }
}
