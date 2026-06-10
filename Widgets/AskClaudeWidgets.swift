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
            // The bridge caches /usage for 60s; watchOS grants roughly a
            // handful of refreshes per hour, so 20 minutes is a safe ask.
            let next = Date().addingTimeInterval(20 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    static func fetch() async -> UsageEntry {
        let usage = try? await BridgeClient().usage()
        return UsageEntry(
            date: Date(),
            fiveHour: usage?.five_hour?.utilization,
            sevenDay: usage?.seven_day?.utilization
        )
    }
}

private func usageTint(_ pct: Double?) -> Color {
    switch pct ?? 0 {
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
            case .accessoryCorner:
                UsageRing(label: bucket.short, pct: pct)
            default:
                ActivityRings(entry: entry)
            }
        }
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
