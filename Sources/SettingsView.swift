import SwiftUI
import WidgetKit

struct SettingsView: View {
    @AppStorage("bridgeHost", store: BridgeConfig.suite) private var host = BridgeConfig.defaultHost
    @AppStorage("bridgePort", store: BridgeConfig.suite) private var port = BridgeConfig.defaultPort
    @AppStorage("bridgeToken", store: BridgeConfig.suite) private var token = BridgeConfig.defaultToken
    @AppStorage("modelAlias") private var modelAlias = ClaudeModel.fable.rawValue
    @AppStorage("model1M") private var oneMillion = false
    @AppStorage("effortLevel") private var effortLevel = EffortLevel.auto.rawValue
    @AppStorage("animateReplies") private var animateReplies = true
    @AppStorage("animateCPS") private var animateCPS = 120
    @AppStorage("suggestReplies") private var suggestReplies = true
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
            Section("Chat") {
                Toggle("Animate replies", isOn: $animateReplies)
                Picker("Speed", selection: $animateCPS) {
                    Text("Slow").tag(60)
                    Text("Normal").tag(120)
                    Text("Fast").tag(240)
                }
                .disabled(!animateReplies)
                Toggle("Suggest replies", isOn: $suggestReplies)
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
        .onAppear {
            // Builds before Haiku 5.5 stored the bare "haiku" alias, which the
            // CLI now resolves to Haiku 5.5.
            if modelAlias == "haiku" { modelAlias = ClaudeModel.haiku55.rawValue }
        }
        .onChange(of: modelAlias) { _, _ in clampInvalidChoices() }
        .onChange(of: oneMillion) { _, _ in clampInvalidChoices() }
        .onChange(of: host) { _, _ in WidgetCenter.shared.reloadAllTimelines() }
        .onChange(of: port) { _, _ in WidgetCenter.shared.reloadAllTimelines() }
        .onChange(of: token) { _, _ in WidgetCenter.shared.reloadAllTimelines() }
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
                // The bridge debounces its switch-confirmation auto-accept
                // over a 3s window per dialog instance; a shorter gap lands
                // /effort's own confirmation inside that window, where it
                // gets silently swallowed and /effort never applies.
                try await Task.sleep(for: .seconds(3.5))
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
