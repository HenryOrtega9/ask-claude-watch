import SwiftUI

struct SettingsView: View {
    @AppStorage("bridgeHost") private var host = BridgeConfig.defaultHost
    @AppStorage("bridgePort") private var port = BridgeConfig.defaultPort
    @AppStorage("bridgeToken") private var token = BridgeConfig.defaultToken
    @State private var status = ""

    var body: some View {
        Form {
            Section("Bridge") {
                TextField("Host", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
                TextField("Token", text: $token)
                    .textContentType(.password)
            }
            Section {
                Button("Test connection") {
                    testConnection()
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
    }

    private func testConnection() {
        status = "Testing…"
        Task {
            do {
                guard let url = BridgeConfig.url("/health") else {
                    status = "Bad URL"
                    return
                }
                var req = URLRequest(url: url)
                req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200,
                   let health = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let state = health["state"] as? String {
                    status = "Connected. Bridge is \(state)."
                } else {
                    status = "HTTP \(code)"
                }
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
