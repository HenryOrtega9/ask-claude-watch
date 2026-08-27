import SwiftUI
import WidgetKit

/// Claude plan usage gauges, fed by the bridge's /usage proxy of Anthropic's
/// OAuth usage endpoint (same data as the ClaudeUsageBar menu bar app).
struct UsageView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var usage: UsageResponse?
    @State private var error: String?
    @State private var loading = false
    @State private var lastLoaded: Date?

    private let client = BridgeClient()

    var body: some View {
        List {
            if let usage {
                if let error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                if let limits = usage.limits, !limits.isEmpty {
                    ForEach(limits) { limit in
                        UsageRow(
                            title: limit.displayLabel,
                            bucket: UsageBucket(utilization: limit.percent, resets_at: limit.resets_at)
                        )
                    }
                } else {
                    // Legacy shape fallback: `limits` supersedes these once
                    // the bridge reports it, but older bridge builds only
                    // send the top-level buckets. UsageRow hides any bucket
                    // whose utilization is nil, so a retired field here (or
                    // an all-nil error payload) renders nothing instead of a
                    // fabricated 0%.
                    UsageRow(title: "5 hour", bucket: usage.five_hour)
                    UsageRow(title: "7 day", bucket: usage.seven_day)
                    UsageRow(title: "Sonnet 7d", bucket: usage.seven_day_sonnet)
                    UsageRow(title: "Opus 7d", bucket: usage.seven_day_opus)
                    UsageRow(title: "Design 7d", bucket: usage.seven_day_omelette)
                }
                if let extra = usage.extra_usage, extra.is_enabled == true {
                    extraUsageRow(extra)
                }
                if let lastLoaded {
                    HStack(spacing: 3) {
                        Text("Updated")
                        Text(lastLoaded, style: .relative)
                        Text("ago")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await load() } }
        }
    }

    private func extraUsageRow(_ extra: UsageResponse.ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Extra usage")
                .font(.footnote)
            if let used = extra.used_credits, let limit = extra.monthly_limit, limit > 0 {
                Gauge(value: min(used / limit, 1)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.purple)
                Text("\(formattedAmount(cents: used, currency: extra.currency)) of \(formattedAmount(cents: limit, currency: extra.currency))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let used = extra.used_credits {
                Text(formattedAmount(cents: used, currency: extra.currency))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formattedAmount(cents: Double, currency: String?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency ?? "USD"
        return formatter.string(from: NSNumber(value: cents / 100)) ?? String(format: "%.2f", cents / 100)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            usage = try await client.usage()
            error = nil
            lastLoaded = Date()
            UsageCache.save(fiveHour: usage?.five_hour?.utilization, sevenDay: usage?.seven_day?.utilization)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct UsageRow: View {
    let title: String
    let bucket: UsageBucket?

    /// nil (bucket absent, or present with a null utilization — a retired
    /// or not-yet-populated field) must never collapse to a fabricated 0%.
    private var pct: Double? { bucket?.utilization }

    private var tint: Color {
        switch pct ?? 0 {
        case ..<50: return .green
        case ..<80: return .yellow
        default: return .red
        }
    }

    var body: some View {
        if let pct {
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
}
