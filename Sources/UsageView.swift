import SwiftUI

/// Claude plan usage gauges, fed by the bridge's /usage proxy of Anthropic's
/// OAuth usage endpoint (same data as the ClaudeUsageBar menu bar app).
struct UsageView: View {
    @State private var usage: UsageResponse?
    @State private var error: String?
    @State private var loading = false

    private let client = BridgeClient()

    var body: some View {
        List {
            if let usage {
                UsageRow(title: "5 hour", bucket: usage.five_hour)
                UsageRow(title: "7 day", bucket: usage.seven_day)
                UsageRow(title: "Sonnet 7d", bucket: usage.seven_day_sonnet)
                if usage.seven_day_opus != nil {
                    UsageRow(title: "Opus 7d", bucket: usage.seven_day_opus)
                }
                if usage.seven_day_omelette != nil {
                    UsageRow(title: "Design 7d", bucket: usage.seven_day_omelette)
                }
                if let extra = usage.extra_usage, extra.is_enabled == true {
                    extraUsageRow(extra)
                }
            } else if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Loading…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Usage")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .task { await load() }
    }

    private func extraUsageRow(_ extra: UsageResponse.ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Extra usage")
                .font(.footnote)
            if let used = extra.used_credits, let limit = extra.monthly_limit, limit > 0 {
                Gauge(value: min(used / limit, 1)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.purple)
                Text("$\(used / 100, specifier: "%.2f") of $\(limit / 100, specifier: "%.2f")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            usage = try await client.usage()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct UsageRow: View {
    let title: String
    let bucket: UsageBucket?

    private var pct: Double { bucket?.utilization ?? 0 }

    private var tint: Color {
        switch pct {
        case ..<50: return .green
        case ..<80: return .yellow
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.footnote)
                Spacer()
                Text("\(Int(pct.rounded()))%")
                    .font(.footnote)
                    .foregroundStyle(tint)
            }
            Gauge(value: min(pct, 100), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(tint)
            if let reset = bucket?.resetsAtDate {
                HStack(spacing: 3) {
                    Text("resets")
                    Text(reset, style: .relative)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
    }
}
