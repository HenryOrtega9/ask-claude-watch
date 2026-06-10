import SwiftUI

struct SettingsView: View {
    @AppStorage("bridgeHost") private var host = BridgeConfig.defaultHost
    @AppStorage("bridgePort") private var port = BridgeConfig.defaultPort
    @AppStorage("bridgeToken") private var token = BridgeConfig.defaultToken
    @AppStorage("modelAlias") private var modelAlias = ClaudeModel.fable.rawValue
    @AppStorage("model1M") private var oneMillion = false
    @AppStorage("effortLevel") private var effortLevel = EffortLevel.auto.rawValue
    @State private var status = ""
    @State private var modelStatus = ""
    @State private var applying = false

    private var model: ClaudeModel { ClaudeModel(rawValue: modelAlias) ?? .fable }
    private var effort: EffortLevel { EffortLevel(rawValue: effortLevel) ?? .auto }

    var body: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: $modelAlias) {
                    ForEach(ClaudeModel.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                Toggle("1M context", isOn: $oneMillion)
                    .disabled(!model.supports1M)
                Picker("Effort", selection: $effortLevel) {
                    ForEach(EffortLevel.available(for: model, oneMillion: oneMillion)) { e in
                        Text(e.label).tag(e.rawValue)
                    }
                }
                Button(applying ? "Applying…" : "Apply to session") {
                    applyModel()
                }
                .disabled(applying)
                if !modelStatus.isEmpty {
                    Text(modelStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
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
        .onChange(of: modelAlias) { _, _ in clampInvalidChoices() }
        .onChange(of: oneMillion) { _, _ in clampInvalidChoices() }
    }

    /// Keep stored choices legal when the model changes underneath them:
    /// drop the 1M flag on Haiku, and drop xhigh when it stops being offered.
    private func clampInvalidChoices() {
        if !model.supports1M { oneMillion = false }
        if !EffortLevel.available(for: model, oneMillion: oneMillion).contains(effort) {
            effortLevel = EffortLevel.high.rawValue
        }
    }

    private func applyModel() {
        applying = true
        modelStatus = "Switching…"
        let modelCommand = "/model \(model.commandValue(oneMillion: oneMillion))"
        let effortCommand = "/effort \(effort.rawValue)"
        Task {
            defer { applying = false }
            do {
                let client = BridgeClient()
                _ = try await client.command(modelCommand)
                try await Task.sleep(for: .seconds(1))
                _ = try await client.command(effortCommand)
                modelStatus = "Now on \(model.label)\(oneMillion && model.supports1M ? " 1M" : ""), \(effort.label) effort."
            } catch {
                modelStatus = error.localizedDescription
            }
        }
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
