import Foundation
import SwiftUI

/// Bridge connection settings, persisted in the shared app-group UserDefaults
/// so the widget extension sees the same values the Settings screen writes.
/// First-launch defaults come from the gitignored Secrets.swift so no tailnet
/// details land in the repo; everything is editable from the Settings screen.
enum BridgeConfig {
    static let defaultHost = Secrets.bridgeHost
    static let defaultPort = 8787
    static let defaultToken = Secrets.bridgeToken
    /// The vault gateway (WHOOP summary) runs on the same Mac mini as the
    /// bridge, on its own port, and takes its own read-only token.
    static let defaultGatewayPort = 8788
    static let defaultWhoopToken = Secrets.whoopToken
    /// The read-only Notes page uses the same gateway with a third token
    /// that only opens /files, /file and /note/resolve.
    static let defaultNotesToken = Secrets.notesToken

    static let appGroup = "group.dev.henryortega.askclaude"
    static let suite = UserDefaults(suiteName: BridgeConfig.appGroup) ?? .standard

    @AppStorage("bridgeHost", store: BridgeConfig.suite) static var host: String = BridgeConfig.defaultHost
    @AppStorage("bridgePort", store: BridgeConfig.suite) static var port: Int = BridgeConfig.defaultPort
    @AppStorage("bridgeToken", store: BridgeConfig.suite) static var token: String = BridgeConfig.defaultToken
    @AppStorage("gatewayPort", store: BridgeConfig.suite) static var gatewayPort: Int = BridgeConfig.defaultGatewayPort
    @AppStorage("whoopToken", store: BridgeConfig.suite) static var whoopToken: String = BridgeConfig.defaultWhoopToken
    @AppStorage("notesToken", store: BridgeConfig.suite) static var notesToken: String = BridgeConfig.defaultNotesToken

    /// The bridge moved from the MacBook Pro to the Mac mini on 2026-09-22.
    /// Rewrites a stored host that still names the MacBook so existing
    /// installs follow the move; any other value is left alone.
    static func migrateToMacMiniIfNeeded() {
        let saved = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if saved == "100.96.112.74" || saved == "henrys-macbook-pro.tail92466c.ts.net" {
            host = "100.114.225.49"
        }
    }

    static func url(_ path: String) -> URL? {
        URL(string: "http://\(host):\(port)\(path)")
    }

    /// A vault gateway URL: same tailnet host as the bridge, gateway port.
    static func gatewayURL(_ path: String) -> URL? {
        URL(string: "http://\(host):\(gatewayPort)\(path)")
    }
}

/// Last successfully fetched /usage values, shared via the app group so the
/// widget extension can fall back to a real (if stale) reading instead of
/// rendering "no data" identically to a genuine 0% when the bridge is
/// unreachable.
enum UsageCache {
    private static let fiveHourKey = "cachedUsageFiveHour"
    private static let sevenDayKey = "cachedUsageSevenDay"
    private static let dateKey = "cachedUsageDate"

    static func save(fiveHour: Double?, sevenDay: Double?) {
        let suite = BridgeConfig.suite
        if let fiveHour { suite.set(fiveHour, forKey: fiveHourKey) } else { suite.removeObject(forKey: fiveHourKey) }
        if let sevenDay { suite.set(sevenDay, forKey: sevenDayKey) } else { suite.removeObject(forKey: sevenDayKey) }
        suite.set(Date(), forKey: dateKey)
    }

    static func load() -> (fiveHour: Double?, sevenDay: Double?, date: Date)? {
        let suite = BridgeConfig.suite
        guard let date = suite.object(forKey: dateKey) as? Date else { return nil }
        let fiveHour = suite.object(forKey: fiveHourKey) as? Double
        let sevenDay = suite.object(forKey: sevenDayKey) as? Double
        return (fiveHour, sevenDay, date)
    }
}
