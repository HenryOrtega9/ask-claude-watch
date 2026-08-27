import Foundation

/// Thin async client for the Mac-side watch bridge. One blocking POST per
/// chat turn; the bridge enforces single-turn serialization and returns 202
/// with partial=true if its reply budget expires while Claude is still
/// working (fetch /last afterwards for the finished reply).
struct BridgeClient {
    /// The full /chat turn budget, and /wait's bounded server-side block.
    /// Fast bridge-local reads/writes (usage, sessions, /last, /reset,
    /// /command) must never inherit this — a widget extension only gets a
    /// few seconds before WidgetKit terminates it, and an unreachable bridge
    /// drops packets rather than refusing them, so a shared long timeout
    /// hangs those calls for the full window.
    private enum RequestBudget { case blocking, quick }

    /// Slack subtracted from a `since` timestamp to absorb watch/Mac clock
    /// skew. Shared with TurnNotifier's background long-poll (which cannot
    /// import this struct's app-only counterpart, since it does not compile
    /// into the widget extension target that also links BridgeClient) so
    /// both the foreground check-again poll and the background wait agree.
    static let skewSlack: TimeInterval = 2

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 150
        return URLSession(configuration: config)
    }()

    private static let quickSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    func chat(_ message: String) async throws -> ChatResponse {
        try await request(path: "/chat", method: "POST", body: ["message": message], budget: .blocking)
    }

    /// Poll the bridge's turn-completion primitive: unlike /last's single
    /// unscoped slot (which holds whichever turn finished most recently,
    /// with no link to the turn being waited on), /wait only returns 200
    /// once a turn completed at or after `since`, so an older, already-seen
    /// completion can never be mistaken for the one in flight.
    func wait(since: Date, timeout: Int) async throws -> ChatResponse {
        let sinceEpoch = Int(since.timeIntervalSince1970 - Self.skewSlack)
        return try await request(
            path: "/wait?since=\(sinceEpoch)&timeout=\(timeout)",
            method: "GET",
            body: nil,
            budget: .blocking
        )
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

    private func request(
        path: String, method: String, body: [String: String]?, budget: RequestBudget = .quick
    ) async throws -> ChatResponse {
        let (data, status) = try await raw(path: path, method: method, body: body, budget: budget)
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

    private func raw(
        path: String, method: String, body: [String: String]?, budget: RequestBudget = .quick
    ) async throws -> (Data, Int) {
        guard let url = BridgeConfig.url(path) else { throw BridgeError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let urlSession = budget == .blocking ? Self.session : Self.quickSession
        let (data, response) = try await urlSession.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func error(for status: Int, data: Data) -> BridgeError {
        if status == 401 { return .unauthorized }
        let message = (try? JSONDecoder().decode(ChatResponse.self, from: data))?.error
        return .server(message ?? "Bridge error (HTTP \(status))")
    }
}
