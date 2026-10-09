import SwiftUI
import WidgetKit

/// Watch-face complications showing Claude plan-limit utilization as rings,
/// fed by the bridge's /usage endpoint. Tapping any complication launches
/// the app. Two kinds (5-hour and 7-day) so both rings can sit on one face.
@main
struct AskClaudeWidgets: WidgetBundle {
    var body: some Widget {
        FiveHourWidget()
        SevenDayWidget()
        DualRingWidget()
    }
}

enum UsageWidgetBucket {
    case fiveHour
    case sevenDay

    var short: String { self == .fiveHour ? "5H" : "7D" }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let fiveHour: Double?
    let sevenDay: Double?
    /// True when these values came from the last cached fetch rather than a
    /// fresh one — the bridge was unreachable this refresh cycle, or it
    /// could not reach Anthropic and flagged its own reading stale. Distinct
    /// from "no data" (nil values): a stale reading is real usage, just old.
    var isStale: Bool = false
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), fiveHour: 42, sevenDay: 17)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await Self.fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let entry = await Self.fetch()
            let noData = entry.fiveHour == nil && entry.sevenDay == nil
            // The bridge caches /usage for 60s; watchOS grants roughly a
            // handful of refreshes per hour, so 20 minutes is a safe ask on
            // success. On a failed/stale fetch, retry sooner rather than
            // leaving a stale or empty ring showing for the full window.
            let next = Date().addingTimeInterval(entry.isStale || noData ? 5 * 60 : 20 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    static func fetch() async -> UsageEntry {
        if let usage = try? await BridgeClient().usage() {
            let fiveHour = usage.five_hour?.utilization
            let sevenDay = usage.seven_day?.utilization
            if usage.isStale {
                // The bridge reached us but not Anthropic, and served its
                // last good reading: show it dimmed, retry on the short
                // cadence, and never stamp it into the cache as fresh.
                return UsageEntry(
                    date: usage.cachedAtDate ?? Date(),
                    fiveHour: fiveHour,
                    sevenDay: sevenDay,
                    isStale: true
                )
            }
            UsageCache.save(fiveHour: fiveHour, sevenDay: sevenDay)
            return UsageEntry(date: Date(), fiveHour: fiveHour, sevenDay: sevenDay)
        }
        // Bridge unreachable this cycle: fall back to the last known-good
        // reading (shared with the app via the app group) instead of
        // rendering indistinguishable-from-genuinely-0% empty rings.
        if let cached = UsageCache.load() {
            return UsageEntry(date: cached.date, fiveHour: cached.fiveHour, sevenDay: cached.sevenDay, isStale: true)
        }
        return UsageEntry(date: Date(), fiveHour: nil, sevenDay: nil)
    }
}

private func usageTint(_ pct: Double?) -> Color {
    // No data (unreachable bridge, nothing cached yet) must read visually
    // distinct from a genuine, freshly-fetched 0% — never collapse to green.
    guard let pct else { return .gray }
    switch pct {
    case ..<50: return .green
    case ..<80: return .yellow
    default: return .red
    }
}

private struct UsageRing: View {
    let label: String
    let pct: Double?

    var body: some View {
        Gauge(value: min(max(pct ?? 0, 0), 100), in: 0...100) {
            Text(label)
        } currentValueLabel: {
            Text(pct.map { "\(Int($0.rounded()))" } ?? "—")
        }
        .gaugeStyle(.accessoryCircular)
        .tint(usageTint(pct))
    }
}

private struct RingArc: View {
    let pct: Double?
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        let fraction = min(max((pct ?? 0) / 100, 0), 1)
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Activity-style concentric rings: outer = 5-hour, inner = 7-day. Each
/// sweeps clockwise from 12 o'clock and fills as the limit is consumed.
private struct ActivityRings: View {
    let entry: UsageEntry

    private static let lineWidth: CGFloat = 5.5

    private static let coral = Color(red: 0.91, green: 0.44, blue: 0.29)

    var body: some View {
        ZStack {
            RingArc(pct: entry.fiveHour, color: Self.coral, lineWidth: Self.lineWidth)
            RingArc(pct: entry.sevenDay, color: .mint, lineWidth: Self.lineWidth)
                .padding(Self.lineWidth + 1.5)
            Image(systemName: "asterisk")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Self.coral)
        }
        .padding(1)
    }
}

private struct UsageBar: View {
    let label: String
    let pct: Double?

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 20, alignment: .leading)
            Gauge(value: min(max(pct ?? 0, 0), 100), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(usageTint(pct))
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 11))
                .frame(width: 32, alignment: .trailing)
        }
    }
}

private struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry
    let bucket: UsageWidgetBucket

    private var pct: Double? {
        bucket == .fiveHour ? entry.fiveHour : entry.sevenDay
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text("Claude \(bucket.short) \(pct.map { "\(Int($0.rounded()))%" } ?? "—")")
            case .accessoryRectangular:
                VStack(spacing: 3) {
                    UsageBar(label: "5h", pct: entry.fiveHour)
                    UsageBar(label: "7d", pct: entry.sevenDay)
                }
            default:
                // Covers .accessoryCorner and .accessoryCircular. The
                // circular family previously drew a combined 5h+7d ring
                // here regardless of `bucket`, so placing one of each kind
                // as circular complications rendered two identical rings;
                // each kind now shows only its own bucket, like every other
                // family above.
                UsageRing(label: bucket.short, pct: pct)
            }
        }
        .opacity(entry.isStale ? 0.55 : 1)
        .containerBackground(for: .widget) { Color.clear }
    }
}

private struct DualRingWidgetView: View {
    let entry: UsageEntry

    var body: some View {
        ActivityRings(entry: entry)
            .opacity(entry.isStale ? 0.55 : 1)
            .containerBackground(for: .widget) { Color.clear }
    }
}

struct FiveHourWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AskClaudeUsage5h", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry, bucket: .fiveHour)
        }
        .configurationDisplayName("Claude 5-hour")
        .description("5-hour limit usage ring.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct SevenDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AskClaudeUsage7d", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry, bucket: .sevenDay)
        }
        .configurationDisplayName("Claude 7-day")
        .description("7-day limit usage ring.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct DualRingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AskClaudeUsageRings", provider: UsageProvider()) { entry in
            DualRingWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Rings")
        .description("Combined rings: outer 5-hour, inner 7-day.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}
