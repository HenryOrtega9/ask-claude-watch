import Foundation

enum WhoopClientError: Error {
    case badURL
    case http(Int)
}

/// Reads the vault gateway's WHOOP summary. Compiled into both the app and
/// the widget extension. A widget extension only gets a few seconds before
/// WidgetKit terminates it, and an unreachable tailnet host drops packets
/// rather than refusing them, so the request budget is short.
struct WhoopClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func summary() async throws -> WhoopSummary {
        guard let url = BridgeConfig.gatewayURL("/whoop/summary") else { throw WhoopClientError.badURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(BridgeConfig.whoopToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // The gateway answers 200 once authorized; auth, stale and
        // last_error travel in the body.
        guard status == 200 else { throw WhoopClientError.http(status) }
        return try WhoopSummary.decode(data)
    }

    /// One widget refresh: fetch, cache a decoded answer, and fall back to
    /// the cached summary when the gateway cannot be reached. `fetchOK` is
    /// false whenever the live fetch failed, cached data or not.
    /// `tokenRejected` marks a 401/403: the gateway is up but refuses the
    /// WHOOP token, which no amount of retrying fixes.
    static func load() async -> (summary: WhoopSummary?, fetchOK: Bool, tokenRejected: Bool) {
        do {
            let summary = try await WhoopClient().summary()
            WhoopCache.save(summary)
            return (summary, true, false)
        } catch WhoopClientError.http(let status) where status == 401 || status == 403 {
            return (WhoopCache.load(), false, true)
        } catch {
            return (WhoopCache.load(), false, false)
        }
    }
}

/// Last decoded summary, kept in the shared app-group defaults so the app
/// and the widget extension see the same copy. Staleness is judged from the
/// summary's own fetched_at, so the cache does not need its own timestamp.
enum WhoopCache {
    private static let key = "cachedWhoopSummary"

    static func save(_ summary: WhoopSummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        BridgeConfig.suite.set(data, forKey: key)
    }

    static func load() -> WhoopSummary? {
        guard let data = BridgeConfig.suite.data(forKey: key) else { return nil }
        return try? WhoopSummary.decode(data)
    }
}
