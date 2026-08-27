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

    static let appGroup = "group.dev.henryortega.askclaude"
    static let suite = UserDefaults(suiteName: BridgeConfig.appGroup) ?? .standard

    @AppStorage("bridgeHost", store: BridgeConfig.suite) static var host: String = BridgeConfig.defaultHost
    @AppStorage("bridgePort", store: BridgeConfig.suite) static var port: Int = BridgeConfig.defaultPort
    @AppStorage("bridgeToken", store: BridgeConfig.suite) static var token: String = BridgeConfig.defaultToken

    static func url(_ path: String) -> URL? {
        URL(string: "http://\(host):\(port)\(path)")
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
