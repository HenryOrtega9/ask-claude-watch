import Foundation
import SwiftUI

/// Bridge connection settings, persisted in the shared app-group UserDefaults
/// so the widget extension sees the same values the Settings screen writes.
/// Defaults match the Mac's tailnet bridge so the app works out of the box on
/// Henry's devices; everything is editable from the Settings screen.
enum BridgeConfig {
    static let defaultHost = "100.96.112.74"
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
