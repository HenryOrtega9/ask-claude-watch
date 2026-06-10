import Foundation
import SwiftUI

/// Bridge connection settings, persisted in UserDefaults. Defaults match the
/// Mac's tailnet bridge so the app works out of the box on Henry's devices;
/// everything is editable from the Settings screen.
enum BridgeConfig {
    static let defaultHost = "100.96.112.74"
    static let defaultPort = 8787
    static let defaultToken = Secrets.bridgeToken

    @AppStorage("bridgeHost") static var host: String = BridgeConfig.defaultHost
    @AppStorage("bridgePort") static var port: Int = BridgeConfig.defaultPort
    @AppStorage("bridgeToken") static var token: String = BridgeConfig.defaultToken

    static func url(_ path: String) -> URL? {
        URL(string: "http://\(host):\(port)\(path)")
    }
}
