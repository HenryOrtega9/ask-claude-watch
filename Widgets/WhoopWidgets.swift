import SwiftUI
import WidgetKit

/// WHOOP complications fed by the vault gateway's GET /whoop/summary on the
/// Mac mini. Designs from the WHOOP complication gallery:
///   C2 Recovery + Strain Rings (accessoryCircular)
///   C6 Triad (accessoryCircular)
///   R6 Strain Today, R8 Week Trends and R10 Three Rings + Detail
///   (accessoryRectangular, round 2, middle slot)
/// Geometry follows the gallery's generator in watch points: circular art on
/// a 50 x 50 grid, rectangular on 170 x 78, scaled to the real slot size.

// MARK: - Display model

/// What a complication should show for one summary at one moment. Pure, so
/// a timeline can hold future entries that age into the stale style.
struct WhoopDisplay {
    enum Offline { case setup, reconnect, error }
    enum Phase: Equatable { case live, stale, offline(Offline) }

    /// Design rule: 60 minutes with no successful sync from the Mac mini
    /// (two missed refreshes) turns everything gray.
    static let staleAfter: TimeInterval = 60 * 60

    var phase: Phase
    /// Age of the data ("45m", "2h", "3d"); nil when there is no data.
    var ageLabel: String?

    var recoveryPending: Bool
    /// Text shown where the detail lines go while recovery is pending.
    var recoveryNote: String
    var recovery: Int?
    var band: WhoopBand
    var hrv: Int?
    var rhr: Int?

    /// Strain is never pending: 0.0 until the new cycle has any.
    var strain: Double
    var kcal: Int?

    var sleepPending: Bool
    var sleepNote: String
    var sleepPct: Int?
    var slept: Double?
    var needed: Double?

    /// No summary at all: nothing from the gateway and nothing cached.
    var noData: Bool

    struct Day: Identifiable {
        let id: Int
        /// Single-letter weekday in the user's locale.
        let letter: String
        let recovery: Int?
        let band: WhoopBand
        let strain: Double?
    }

    /// Exactly seven days ending on the current cycle's day, or empty when
    /// the gateway sent no history. Days missing from the feed hold nils.
    var week: [Day]

    struct Step { let t: Date; let strain: Double }
    struct Span { let sport: String; let start: Date; let end: Date }

    /// Strain Today x range: wake (or the cycle start) to fetched_at.
    var chartStart: Date?
    var chartStartIsWake: Bool
    var chartEnd: Date?
    /// Step points, oldest first.
    var steps: [Step]
    /// Today's workouts, oldest first.
    var workouts: [Span]

    var isStale: Bool { phase == .stale }

    init(summary: WhoopSummary?, now: Date) {
        let s = summary
        let fetched = s?.fetchedAtDate

        switch s?.auth {
        case .notConfigured?:
            phase = .offline(.setup)
        case .reauthRequired?:
            phase = .offline(.reconnect)
        case .error?, .unknown?:
            // A gateway that cannot refresh still serves its last data;
            // only with nothing to show is it an outright error.
            phase = fetched == nil ? .offline(.error) : Self.agePhase(fetched, now)
        case .ok?:
            phase = Self.agePhase(fetched, now)
        case nil:
            // No answer from the gateway and nothing cached.
            phase = .stale
        }
        ageLabel = fetched.map { Self.age(from: $0, to: now) }

        let rec = s?.recovery
        recoveryPending = !(s?.recoveryScoredToday ?? false)
        if let rec, rec.isCurrentCycle, rec.state == .unscorable {
            recoveryNote = "Unscored"
        } else if s == nil || (rec?.state == .missing && rec?.isCurrentCycle == true && fetched == nil) {
            recoveryNote = "No data"
        } else {
            recoveryNote = "Scoring"
        }
        recovery = rec?.score
        if let b = rec?.band, b != .unknown {
            band = b
        } else {
            band = .forScore(rec?.score ?? 0)
        }
        hrv = rec?.hrvMs.map { Int($0.rounded()) }
        rhr = rec?.rhrBpm

        strain = max(0, s?.strain.dayStrain ?? 0)
        kcal = s?.strain.kcal

        let sl = s?.sleep
        sleepPending = !(sl?.state == .scored && sl?.performancePct != nil)
        sleepNote = sl?.state == .unscorable ? "Unscored" : (s == nil ? "No data" : "Scoring")
        sleepPct = sl?.performancePct
        slept = sl?.hoursSlept
        needed = sl?.hoursNeeded

        noData = s == nil
        week = Self.week(s?.week ?? [])

        let st = s?.strainToday
        let wake = WhoopDate.parse(st?.wake)
        steps = (st?.points ?? [])
            .compactMap { p in WhoopDate.parse(p.t).map { Step(t: $0, strain: max(0, p.strain)) } }
            .sorted { $0.t < $1.t }
        chartStart = wake ?? WhoopDate.parse(st?.cycleStart) ?? WhoopDate.parse(s?.strain.cycleStart) ?? steps.first?.t
        chartStartIsWake = wake != nil
        chartEnd = [fetched, steps.last?.t].compactMap { $0 }.max()
        workouts = (s?.workoutsToday ?? []).compactMap { w in
            guard let a = WhoopDate.parse(w.start), let b = WhoopDate.parse(w.end), b > a else { return nil }
            return Span(sport: w.sport, start: a, end: b)
        }
    }

    /// Lays the feed's history onto seven calendar days ending at its last
    /// entry, so a skipped day keeps its slot and its letter.
    private static func week(_ feed: [WhoopSummary.WeekDay]) -> [Day] {
        guard let last = WhoopDate.parseDay(feed.last?.day) else { return [] }
        var byDay: [String: WhoopSummary.WeekDay] = [:]
        for e in feed { if let d = e.day { byDay[d] = e } }
        var greg = Calendar(identifier: .gregorian)
        greg.timeZone = .current
        let letters = Calendar.current.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { i in
            let date = greg.date(byAdding: .day, value: i - 6, to: last) ?? last
            let e = byDay[WhoopDate.dayString(date)]
            let weekday = greg.component(.weekday, from: date)
            let band: WhoopBand
            if let b = e?.band, b != .unknown {
                band = b
            } else {
                band = .forScore(e?.recovery ?? 0)
            }
            return Day(id: i, letter: letters.indices.contains(weekday - 1) ? letters[weekday - 1] : "",
                       recovery: e?.recovery, band: band, strain: e?.strain.map { max(0, $0) })
        }
    }

    private static func agePhase(_ fetched: Date?, _ now: Date) -> Phase {
        guard let fetched else { return .stale }
        return now.timeIntervalSince(fetched) >= staleAfter ? .stale : .live
    }

    static func age(from: Date, to: Date) -> String {
        // Rounded so a timestamp that lost its sub-millisecond part in the
        // ISO round trip still reads 2h at exactly two hours.
        let minutes = max(0, Int((to.timeIntervalSince(from) / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// WHOOP strain zones: Light under 10, Moderate 10 to 13.9, High 14 to
    /// 17.9, All out 18 and up.
    static func zone(_ strain: Double) -> String {
        if strain < 10 { return "Light" }
        if strain < 14 { return "Moderate" }
        if strain < 18 { return "High" }
        return "All out"
    }

    /// 7.2 hours reads "7h 12m".
    static func hm(_ hours: Double) -> String {
        var h = Int(hours)
        var m = Int(((hours - Double(h)) * 60).rounded())
        if m == 60 { h += 1; m = 0 }
        return String(format: "%dh %02dm", h, m)
    }
}

// MARK: - Palette

enum WhoopColors {
    static let recGreen = Color(red: 0x16 / 255, green: 0xEC / 255, blue: 0x06 / 255)
    static let recYellow = Color(red: 0xFF / 255, green: 0xDE / 255, blue: 0x00 / 255)
    static let recRed = Color(red: 0xFF / 255, green: 0x00 / 255, blue: 0x26 / 255)
    static let strain = Color(red: 0x00 / 255, green: 0x93 / 255, blue: 0xE7 / 255)
    static let sleep = Color(red: 0xA9 / 255, green: 0x8B / 255, blue: 0xFF / 255)
    static let fg2 = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)
    static let fg3 = Color(red: 0x5C / 255, green: 0x5C / 255, blue: 0x61 / 255)

    static func band(_ b: WhoopBand) -> Color {
        switch b {
        case .green: return recGreen
        case .yellow: return recYellow
        case .red: return recRed
        case .unknown: return fg2
        }
    }
}

enum WhoopMetric {
    case recovery(WhoopBand), strain, sleep

    var color: Color {
        switch self {
        case .recovery(let b): return WhoopColors.band(b)
        case .strain: return WhoopColors.strain
        case .sleep: return WhoopColors.sleep
        }
    }
}

/// Lets an offscreen render stand in a face tint for the accentable parts.
/// On the watch it stays nil and the system applies the real tint.
private struct WhoopAccentPreviewKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var whoopAccentPreview: Color? {
        get { self[WhoopAccentPreviewKey.self] }
        set { self[WhoopAccentPreviewKey.self] = newValue }
    }
}

/// The generator's color rules. Full color keeps WHOOP's colors. Tinted
/// (accented faces) keeps only alpha: accentable parts take the face tint,
/// everything else renders white at the given opacity. Stale drops all
/// color to gray; on a tinted face gray would come out solid white, so
/// stale tinted uses dim white instead and accents nothing.
struct WhoopPalette {
    let tinted: Bool
    let stale: Bool
    var preview: Color? = nil

    var fg: Color {
        if stale { return tinted ? .white.opacity(0.6) : WhoopColors.fg2 }
        return .white
    }

    var fg2: Color {
        if stale { return tinted ? .white.opacity(0.38) : WhoopColors.fg3 }
        return tinted ? .white.opacity(0.6) : WhoopColors.fg2
    }

    func metric(_ m: WhoopMetric, accent: Bool = false) -> Color {
        if stale { return tinted ? .white.opacity(0.38) : WhoopColors.fg3 }
        if !tinted { return m.color }
        return accent ? (preview ?? .white) : .white
    }

    /// Whether accentable parts should opt into the tint group.
    var accents: Bool { tinted && !stale }

    /// Opacity for a colored part that is NOT accentable: tinted renders it
    /// white, dimmed to `tintOp`.
    func nop(_ tintOp: Double, _ colorOp: Double = 1) -> Double {
        tinted && !stale ? tintOp : colorOp
    }
}

// MARK: - Drawing helpers

private func whoopFont(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
    .system(size: size, weight: weight, design: .rounded)
}

/// An arc in screen points. Angles in degrees, 0 at 12 o'clock, clockwise.
struct WhoopArc: Shape {
    var center: CGPoint
    var radius: CGFloat
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let end = to - from >= 359.999 ? from + 360 : to
        p.addArc(center: center, radius: radius,
                 startAngle: .degrees(from - 90), endAngle: .degrees(end - 90),
                 clockwise: false)
        return p
    }
}

private func roundStroke(_ width: CGFloat) -> StrokeStyle {
    StrokeStyle(lineWidth: width, lineCap: .round)
}

/// Round-capped zero-length dashes read as a dotted track.
private func dottedStroke(_ width: CGFloat, gap: CGFloat) -> StrokeStyle {
    StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.01, gap])
}

extension View {
    /// Places text with its first baseline at `baseline` and its leading
    /// edge, center (anchor 0.5) or trailing edge (1) at `x`, all in points
    /// from the top-left of the enclosing frame. Does not affect layout.
    fileprivate func whoopAt(x: CGFloat, baseline: CGFloat, anchor: CGFloat = 0) -> some View {
        Color.clear.overlay(alignment: .topLeading) {
            self
                .alignmentGuide(.top) { $0[.firstTextBaseline] }
                .alignmentGuide(.leading) { $0.width * anchor }
                .offset(x: x, y: baseline)
        }
    }
}

extension View {
    /// Like whoopAt with a centered anchor, but slides the text so its
    /// measured width stays between `minX` and `maxX`.
    fileprivate func whoopAtClamped(center: CGFloat, minX: CGFloat, maxX: CGFloat, baseline: CGFloat) -> some View {
        Color.clear.overlay(alignment: .topLeading) {
            self
                .fixedSize()
                .alignmentGuide(.top) { $0[.firstTextBaseline] }
                .alignmentGuide(.leading) { dim in
                    -min(max(center - dim.width / 2, minX), maxX - dim.width)
                }
                .offset(y: baseline)
        }
    }
}

/// Fits a design grid of `w` x `h` points into the slot. `s` scales sizes
/// and vertical positions; `sx` scales horizontal positions so a wider slot
/// spreads columns instead of leaving a gap on the right.
private struct WhoopCanvas<Content: View>: View {
    let w: CGFloat
    let h: CGFloat
    var stretchX = false
    @ViewBuilder let content: (_ s: CGFloat, _ sx: CGFloat) -> Content

    var body: some View {
        GeometryReader { geo in
            let s = max(0.01, min(geo.size.width / w, geo.size.height / h))
            let sx = stretchX ? geo.size.width / w : s
            ZStack(alignment: .topLeading) {
                content(s, sx)
            }
            .frame(width: w * sx, height: h * s, alignment: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct WhoopDots: View {
    let cx: CGFloat
    let cy: CGFloat
    let r: CGFloat
    let gap: CGFloat
    let color: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: r * 2, height: r * 2)
                    .position(x: cx + CGFloat(i - 1) * gap, y: cy)
            }
        }
    }
}

/// Rectangle with a diagonal band removed, used to knock the slash gap out
/// of the app glyph without painting black (black would turn white on a
/// tinted face).
private struct WhoopSlashKnockout: Shape {
    let center: CGPoint
    let r: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path(rect.insetBy(dx: -rect.width, dy: -rect.height))
        let hw = 0.375 * r / 2.squareRoot()
        let a = CGPoint(x: center.x - 1.15 * r, y: center.y + 1.15 * r)
        let b = CGPoint(x: center.x + 1.15 * r, y: center.y - 1.15 * r)
        p.move(to: CGPoint(x: a.x - hw, y: a.y - hw))
        p.addLine(to: CGPoint(x: b.x - hw, y: b.y - hw))
        p.addLine(to: CGPoint(x: b.x + hw, y: b.y + hw))
        p.addLine(to: CGPoint(x: a.x + hw, y: a.y + hw))
        p.closeSubpath()
        return p
    }
}

/// The gallery's plain app glyph: an open ring (gap at 12 o'clock) with a
/// center dot, optionally slashed for the not-connected state.
private struct WhoopGlyph: View {
    let center: CGPoint
    let r: CGFloat
    let color: Color
    var slash: Color? = nil
    var slashAccent = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                WhoopArc(center: center, radius: r, from: 35, to: 325)
                    .stroke(color, style: StrokeStyle(lineWidth: r * 0.42, lineCap: .round))
                Circle()
                    .fill(color)
                    .frame(width: r * 0.6, height: r * 0.6)
                    .position(center)
            }
            .mask {
                if slash != nil {
                    WhoopSlashKnockout(center: center, r: r).fill(style: FillStyle(eoFill: true))
                } else {
                    Rectangle()
                }
            }
            if let slash {
                Path { p in
                    p.move(to: CGPoint(x: center.x - 1.05 * r, y: center.y + 1.05 * r))
                    p.addLine(to: CGPoint(x: center.x + 1.05 * r, y: center.y - 1.05 * r))
                }
                .stroke(slash, style: roundStroke(r * 0.32))
                .widgetAccentable(slashAccent)
            }
        }
    }
}

private struct WhoopClockGlyph: View {
    let center: CGPoint
    let r: CGFloat
    let color: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            WhoopArc(center: center, radius: r, from: 0, to: 360)
                .stroke(color, lineWidth: r * 0.32)
            Path { p in
                p.move(to: center)
                p.addLine(to: CGPoint(x: center.x, y: center.y - r * 0.6))
                p.move(to: center)
                p.addLine(to: CGPoint(x: center.x + r * 0.45, y: center.y))
            }
            .stroke(color, style: roundStroke(r * 0.3))
        }
    }
}

// MARK: - Not connected

/// Circular not-connected tile: dim disc, slashed glyph, one word.
struct WhoopOfflineCircularView: View {
    let kind: WhoopDisplay.Offline
    let tinted: Bool
    @Environment(\.whoopAccentPreview) private var accentPreview

    var body: some View {
        let p = WhoopPalette(tinted: tinted, stale: false, preview: accentPreview)
        WhoopCanvas(w: 50, h: 50) { s, _ in
            Circle()
                .fill(Color.white.opacity(0.13))
                .frame(width: 50 * s, height: 50 * s)
            WhoopGlyph(center: CGPoint(x: 25 * s, y: 21 * s), r: 7 * s, color: p.fg2,
                       slash: tinted ? (accentPreview ?? .white) : .white, slashAccent: tinted)
            Text(kind == .setup ? "WHOOP setup" : "Reconnect")
                .font(whoopFont(6.4 * s))
                .foregroundStyle(p.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 40 * s)
                .whoopAt(x: 25 * s, baseline: 39.5 * s, anchor: 0.5)
        }
    }
}

/// Rectangular not-connected card. The gallery mock said "Open AskClaude on
/// iPhone"; the real fix is whoop-auth on the Mac mini, so the copy says so.
struct WhoopOfflineRectangularView: View {
    let kind: WhoopDisplay.Offline
    let tinted: Bool
    @Environment(\.whoopAccentPreview) private var accentPreview

    private var lines: (String, String, String) {
        switch kind {
        case .setup: return ("WHOOP setup", "Run whoop-auth on", "the Mac mini")
        case .reconnect: return ("Reconnect", "Sign in again with", "whoop-auth on the mini")
        case .error: return ("WHOOP error", "Check whoop-auth status", "on the Mac mini")
        }
    }

    var body: some View {
        let p = WhoopPalette(tinted: tinted, stale: false, preview: accentPreview)
        let (title, l1, l2) = lines
        WhoopCanvas(w: 170, h: 78) { s, _ in
            WhoopGlyph(center: CGPoint(x: 4.5 * s, y: 6.5 * s), r: 3.6 * s, color: p.fg2, slash: p.fg2)
            Text("WHOOP")
                .font(whoopFont(8.2 * s))
                .tracking(0.4 * s)
                .foregroundStyle(p.fg2)
                .whoopAt(x: 12 * s, baseline: 10 * s)
            Text(title)
                .font(whoopFont(18 * s))
                .foregroundStyle(tinted ? (accentPreview ?? .white) : .white)
                .widgetAccentable(tinted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 168 * s, alignment: .leading)
                .whoopAt(x: 0, baseline: 36 * s)
            ForEach(Array([l1, l2].enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(whoopFont(9.5 * s, .semibold))
                    .foregroundStyle(p.fg2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 168 * s, alignment: .leading)
                    .whoopAt(x: 0, baseline: (i == 0 ? 53 : 67) * s)
            }
        }
    }
}

// MARK: - C2 Recovery + Strain Rings

/// Outer ring: recovery % in band color. Inner ring: day strain on 0 to 21
/// in strain blue. Recovery score in the center.
struct WhoopRingsView: View {
    let display: WhoopDisplay
    let tinted: Bool
    @Environment(\.whoopAccentPreview) private var accentPreview

    var body: some View {
        if case .offline(let kind) = display.phase {
            WhoopOfflineCircularView(kind: kind, tinted: tinted)
        } else {
            rings
        }
    }

    private var rings: some View {
        let d = display
        let p = WhoopPalette(tinted: tinted, stale: d.isStale, preview: accentPreview)
        let strainFrac = min(max(d.strain / 21, 0), 1)
        return WhoopCanvas(w: 50, h: 50) { s, _ in
            let c = CGPoint(x: 25 * s, y: 25 * s)
            let sc = p.metric(.strain)
            WhoopArc(center: c, radius: 16.4 * s, from: 0, to: 360)
                .stroke(sc, lineWidth: 3.6 * s)
                .opacity(p.nop(0.18, 0.3))
            WhoopArc(center: c, radius: 16.4 * s, from: 0, to: 360 * strainFrac)
                .stroke(sc, style: roundStroke(3.6 * s))
                .opacity(p.nop(0.65))
            if d.recoveryPending {
                WhoopArc(center: c, radius: 22.2 * s, from: 0, to: 360)
                    .stroke(p.fg2, style: dottedStroke(2 * s, gap: 4.4 * s))
                WhoopDots(cx: 25 * s, cy: 25 * s, r: 1.4 * s, gap: 4.4 * s, color: p.fg)
            } else {
                let rc = p.metric(.recovery(d.band), accent: true)
                let frac = min(max(Double(d.recovery ?? 0) / 100, 0), 1)
                WhoopArc(center: c, radius: 22.2 * s, from: 0, to: 360)
                    .stroke(rc, lineWidth: 3.6 * s)
                    .opacity(0.3)
                    .widgetAccentable(p.accents)
                WhoopArc(center: c, radius: 22.2 * s, from: 0, to: 360 * frac)
                    .stroke(rc, style: roundStroke(3.6 * s))
                    .widgetAccentable(p.accents)
                if d.isStale {
                    Text(d.recovery.map(String.init) ?? "--")
                        .font(whoopFont(12.5 * s)).monospacedDigit()
                        .foregroundStyle(p.fg)
                        .whoopAt(x: 25 * s, baseline: 28.5 * s, anchor: 0.5)
                    Text(d.ageLabel ?? "")
                        .font(whoopFont(5.5 * s))
                        .foregroundStyle(p.fg2)
                        .whoopAt(x: 25 * s, baseline: 35 * s, anchor: 0.5)
                } else {
                    Text(d.recovery.map(String.init) ?? "--")
                        .font(whoopFont(13 * s)).monospacedDigit()
                        .foregroundStyle(p.fg)
                        .whoopAt(x: 25 * s, baseline: 29.6 * s, anchor: 0.5)
                }
            }
        }
    }
}

// MARK: - C6 Triad

/// Three 98 degree segments with 22 degree gaps: recovery at the top, strain
/// lower right (0 to 21), sleep performance lower left. Each fills clockwise
/// within its segment. Recovery score in the center.
struct WhoopTriadView: View {
    let display: WhoopDisplay
    let tinted: Bool
    @Environment(\.whoopAccentPreview) private var accentPreview

    var body: some View {
        if case .offline(let kind) = display.phase {
            WhoopOfflineCircularView(kind: kind, tinted: tinted)
        } else {
            triad
        }
    }

    private struct Segment: Identifiable {
        let id: Int
        let metric: WhoopMetric
        let from: Double
        let to: Double
        let frac: Double
        let accent: Bool
        let pending: Bool
    }

    private var triad: some View {
        let d = display
        let p = WhoopPalette(tinted: tinted, stale: d.isStale, preview: accentPreview)
        let segments = [
            Segment(id: 0, metric: .recovery(d.band), from: -49, to: 49,
                    frac: Double(d.recovery ?? 0) / 100, accent: true, pending: d.recoveryPending),
            Segment(id: 1, metric: .strain, from: 71, to: 169,
                    frac: d.strain / 21, accent: false, pending: false),
            Segment(id: 2, metric: .sleep, from: 191, to: 289,
                    frac: Double(d.sleepPct ?? 0) / 100, accent: false, pending: d.sleepPending),
        ]
        return WhoopCanvas(w: 50, h: 50) { s, _ in
            let c = CGPoint(x: 25 * s, y: 25 * s)
            ForEach(segments) { seg in
                if seg.pending {
                    WhoopArc(center: c, radius: 21.5 * s, from: seg.from, to: seg.to)
                        .stroke(p.fg2, style: dottedStroke(2.2 * s, gap: 4.2 * s))
                } else {
                    let col = p.metric(seg.metric, accent: seg.accent)
                    let frac = min(max(seg.frac, 0), 1)
                    WhoopArc(center: c, radius: 21.5 * s, from: seg.from, to: seg.to)
                        .stroke(col, style: roundStroke(4.4 * s))
                        .opacity(seg.accent ? 0.3 : p.nop(0.2, 0.3))
                        .widgetAccentable(seg.accent && p.accents)
                    WhoopArc(center: c, radius: 21.5 * s, from: seg.from, to: seg.from + (seg.to - seg.from) * frac)
                        .stroke(col, style: roundStroke(4.4 * s))
                        .opacity(seg.accent ? 1 : p.nop(0.7))
                        .widgetAccentable(seg.accent && p.accents)
                }
            }
            if d.recoveryPending {
                WhoopDots(cx: 25 * s, cy: 25.5 * s, r: 1.7 * s, gap: 5.2 * s, color: p.fg)
            } else if d.isStale {
                Text(d.recovery.map(String.init) ?? "--")
                    .font(whoopFont(14.5 * s)).monospacedDigit()
                    .foregroundStyle(p.fg)
                    .whoopAt(x: 25 * s, baseline: 29 * s, anchor: 0.5)
                Text(d.ageLabel ?? "")
                    .font(whoopFont(5.5 * s))
                    .foregroundStyle(p.fg2)
                    .whoopAt(x: 25 * s, baseline: 36 * s, anchor: 0.5)
            } else {
                Text(d.recovery.map(String.init) ?? "--")
                    .font(whoopFont(15.5 * s)).monospacedDigit()
                    .foregroundStyle(p.fg)
                    .whoopAt(x: 25 * s, baseline: 30.5 * s, anchor: 0.5)
            }
        }
    }
}

// MARK: - Round 2 helpers

extension WhoopDisplay {
    /// "5:55 AM" in the user's locale.
    static func clock(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }

    /// "6:40", no day period, for the workout label.
    static func clockShort(_ d: Date) -> String {
        d.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }
}

/// Everything except a set of round holes, for an even-odd mask. Stands in
/// for the generator's background-colored rings around dots: painting black
/// would come out white on a tinted face, a hole stays a hole.
private struct WhoopHoles: Shape {
    let holes: [(center: CGPoint, r: CGFloat)]

    func path(in rect: CGRect) -> Path {
        var p = Path(rect.insetBy(dx: -rect.width, dy: -rect.height))
        for h in holes {
            p.addEllipse(in: CGRect(x: h.center.x - h.r, y: h.center.y - h.r, width: h.r * 2, height: h.r * 2))
        }
        return p
    }
}

/// A fixed rectangle in the canvas's own coordinates, for clipping.
private struct WhoopRectClip: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}

/// A path given in canvas coordinates.
private struct WhoopPathShape: Shape {
    let path: Path
    func path(in _: CGRect) -> Path { path }
}

/// The clock glyph sized for a text row.
private struct WhoopSyncedLabel: View {
    let text: String
    let size: CGFloat
    let glyphR: CGFloat
    let color: Color

    var body: some View {
        HStack(spacing: glyphR * 1.1) {
            WhoopClockGlyph(center: CGPoint(x: glyphR * 1.2, y: glyphR * 1.2), r: glyphR, color: color)
                .frame(width: glyphR * 2.4, height: glyphR * 2.4)
            Text(text)
                .font(whoopFont(size, .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - R6 Strain Today

/// Day strain since wake as a step chart with an area fill on 0 to 21,
/// dashed lines at the zone breaks 10, 14 and 18, today's workouts filled
/// brighter (the latest one labeled) and a dot at now. Current value, zone
/// and calories at the left.
struct WhoopStrainTodayView: View {
    let display: WhoopDisplay
    let tinted: Bool
    @Environment(\.whoopAccentPreview) private var accentPreview

    var body: some View {
        if case .offline(let kind) = display.phase {
            WhoopOfflineRectangularView(kind: kind, tinted: tinted)
        } else {
            chart
        }
    }

    private var headerRight: String {
        let d = display
        if d.noData { return "No data" }
        if d.isStale { return d.ageLabel.map { "\($0) ago" } ?? "No data" }
        if let start = d.chartStart {
            return "\(d.chartStartIsWake ? "Woke" : "Since") \(WhoopDisplay.clock(start))"
        }
        return "Cycle not started"
    }

    /// Chart geometry in slot points. The design's x range ends at 170; it
    /// stops 3 pt short here so the now dot (r 2.3) stays inside the slot.
    private struct Geometry {
        let x0: CGFloat, x1: CGFloat, yb: CGFloat, yt: CGFloat
        let start: Date, end: Date

        init?(_ d: WhoopDisplay, s: CGFloat, sx: CGFloat) {
            guard let start = d.chartStart ?? d.steps.first?.t else { return nil }
            x0 = 52 * sx
            x1 = 170 * sx - 3 * s
            yb = 66 * s
            yt = 16 * s
            self.start = start
            end = max(d.chartEnd ?? start, start.addingTimeInterval(60))
        }

        func x(_ t: Date) -> CGFloat {
            let f = min(max(t.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
            return x0 + CGFloat(f) * (x1 - x0)
        }

        func y(_ v: Double) -> CGFloat {
            yb - CGFloat(min(max(v, 0), 21) / 21) * (yb - yt)
        }

        /// Step vertices from the first point (or the range start) to now,
        /// the last step extended to fetched_at. Points before the start
        /// only set the opening value.
        func vertices(_ steps: [WhoopDisplay.Step]) -> [CGPoint] {
            guard !steps.isEmpty else { return [] }
            let before = steps.last { $0.t <= start }
            let after = steps.filter { $0.t > start && $0.t <= end }
            var v: Double
            var pts: [CGPoint]
            var rest = after[...]
            if let before {
                v = before.strain
                pts = [CGPoint(x: x0, y: y(v))]
            } else if let first = rest.popFirst() {
                v = first.strain
                pts = [CGPoint(x: x(first.t), y: y(v))]
            } else {
                return []
            }
            for p in rest {
                let px = x(p.t)
                pts.append(CGPoint(x: px, y: y(v)))
                v = p.strain
                pts.append(CGPoint(x: px, y: y(v)))
            }
            pts.append(CGPoint(x: x1, y: y(v)))
            return pts
        }
    }

    private var chart: some View {
        let d = display
        let p = WhoopPalette(tinted: tinted, stale: d.isStale, preview: accentPreview)
        return WhoopCanvas(w: 170, h: 78, stretchX: true) { s, sx in
            Text("STRAIN TODAY")
                .font(whoopFont(8.2 * s))
                .tracking(0.4 * s)
                .foregroundStyle(tinted ? p.fg2 : p.metric(.strain))
                .lineLimit(1)
                .whoopAt(x: 0, baseline: 10 * s)
            Text(headerRight)
                .font(whoopFont(8.2 * s, .semibold))
                .monospacedDigit()
                .foregroundStyle(p.fg2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 92 * s, alignment: .trailing)
                .whoopAt(x: 170 * sx, baseline: 10 * s, anchor: 1)

            Text(String(format: "%.1f", d.strain))
                .font(whoopFont(22 * s)).monospacedDigit()
                .foregroundStyle(p.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 48 * s, alignment: .leading)
                .whoopAt(x: 0, baseline: 38 * s)
            Text(WhoopDisplay.zone(d.strain))
                .font(whoopFont(8.5 * s))
                .foregroundStyle(tinted || d.isStale ? p.fg2 : p.metric(.strain))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 48 * s, alignment: .leading)
                .whoopAt(x: 0, baseline: 51 * s)
            Text(d.kcal.map { "\($0.formatted(.number)) cal" } ?? "-- cal")
                .font(whoopFont(8 * s, .semibold)).monospacedDigit()
                .foregroundStyle(p.fg2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 48 * s, alignment: .leading)
                .whoopAt(x: 0, baseline: 63 * s)

            plot(d, p: p, s: s, sx: sx)
        }
    }

    @ViewBuilder
    private func plot(_ d: WhoopDisplay, p: WhoopPalette, s: CGFloat, sx: CGFloat) -> some View {
        let x0 = 52 * sx
        let x1 = 170 * sx
        let yb = 66 * s
        let yOf = { (v: Double) in yb - CGFloat(v / 21) * 50 * s }
        ForEach([10, 14, 18], id: \.self) { z in
            Path { path in
                path.move(to: CGPoint(x: x0, y: yOf(Double(z))))
                path.addLine(to: CGPoint(x: x1, y: yOf(Double(z))))
            }
            .stroke(p.fg, style: StrokeStyle(lineWidth: 0.6 * s, dash: [1.5 * s, 2 * s]))
            .opacity(0.22)
            Text("\(z)")
                .font(whoopFont(5.5 * s, .semibold))
                .foregroundStyle(p.fg2)
                .opacity(0.8)
                .whoopAt(x: x0 + 1 * s, baseline: yOf(Double(z)) - 1.6 * s)
        }
        Path { path in
            path.move(to: CGPoint(x: x0, y: yb))
            path.addLine(to: CGPoint(x: x1, y: yb))
        }
        .stroke(p.fg, lineWidth: 0.8 * s)
        .opacity(0.3)
        Text(d.chartStartIsWake || d.chartStart == nil ? "Wake" : "Start")
            .font(whoopFont(6.3 * s, .semibold))
            .foregroundStyle(p.fg2)
            .whoopAt(x: x0, baseline: 76 * s)
        Text("Now")
            .font(whoopFont(6.3 * s, .semibold))
            .foregroundStyle(p.fg2)
            .whoopAt(x: x1, baseline: 76 * s, anchor: 1)

        if let g = Geometry(d, s: s, sx: sx), case let pts = g.vertices(d.steps), let last = pts.last {
            let line = Path { $0.addLines(pts) }
            let area = Path { a in
                a.addLines(pts)
                a.addLine(to: CGPoint(x: last.x, y: g.yb))
                a.addLine(to: CGPoint(x: pts[0].x, y: g.yb))
                a.closeSubpath()
            }
            let sc = p.metric(.strain, accent: true)
            let spans = d.workouts.filter { $0.end > g.start && $0.start < g.end }
            ZStack(alignment: .topLeading) {
                WhoopPathShape(path: area).fill(sc).opacity(0.22)
                ForEach(Array(spans.enumerated()), id: \.offset) { _, w in
                    WhoopPathShape(path: area).fill(sc).opacity(0.62)
                        .clipShape(WhoopRectClip(rect: CGRect(x: g.x(w.start), y: 0,
                                                             width: max(g.x(w.end) - g.x(w.start), 0.8 * s),
                                                             height: g.yb)))
                }
                WhoopPathShape(path: line)
                    .stroke(sc, style: StrokeStyle(lineWidth: 1.4 * s, lineJoin: .round))
            }
            .mask {
                WhoopHoles(holes: [(last, 3.5 * s)]).fill(style: FillStyle(eoFill: true))
            }
            .widgetAccentable(p.accents)
            if let w = spans.last {
                // Centered on the window, kept clear of the zone numbers at
                // the left and inside the slot at the right.
                Text("\(w.sport.prefix(1).uppercased())\(w.sport.dropFirst()) \(WhoopDisplay.clockShort(w.start))")
                    .font(whoopFont(6 * s))
                    .monospacedDigit()
                    .foregroundStyle(p.fg2)
                    .lineLimit(1)
                    .whoopAtClamped(center: (g.x(w.start) + g.x(w.end)) / 2,
                                    minX: g.x0 + 9 * s, maxX: 170 * sx,
                                    baseline: (g.y(14) + g.y(10)) / 2 + 2 * s)
            }
            Circle()
                .fill(p.fg)
                .frame(width: 4.6 * s, height: 4.6 * s)
                .position(last)
        } else {
            Text(d.noData ? "No data yet" : "Starts at wake")
                .font(whoopFont(7.5 * s, .semibold))
                .foregroundStyle(p.fg2)
                .lineLimit(1)
                .whoopAt(x: (x0 + x1) / 2 + 4 * s, baseline: 56 * s, anchor: 0.5)
        }
    }
}

// MARK: - R8 Week Trends

/// Seven days of load against recovery: strain bars on 0 to 21 (right axis),
/// the recovery line on 0 to 100 at the same height through band-colored
/// dots, today's dot larger and labeled, day letters under the chart.
struct WhoopWeekTrendsView: View {
    let display: WhoopDisplay
    let tinted: Bool
    @Environment(\.whoopAccentPreview) private var accentPreview

    var body: some View {
        if case .offline(let kind) = display.phase {
            WhoopOfflineRectangularView(kind: kind, tinted: tinted)
        } else {
            chart
        }
    }

    private var header: String {
        let d = display
        if d.noData { return "7 DAYS · No data" }
        if d.isStale { return "7 DAYS · \(d.ageLabel.map { "\($0) ago" } ?? "No data")" }
        return "7 DAYS"
    }

    private var chart: some View {
        let d = display
        let p = WhoopPalette(tinted: tinted, stale: d.isStale, preview: accentPreview)
        return WhoopCanvas(w: 170, h: 78, stretchX: true) { s, sx in
            let barColor = p.metric(.strain)
            let barOp = p.nop(0.32, 0.6)
            Text(header)
                .font(whoopFont(8.2 * s))
                .tracking(0.4 * s)
                .foregroundStyle(p.fg2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 88 * s, alignment: .leading)
                .whoopAt(x: 0, baseline: 10 * s)
            // Legend, measured rather than placed on the design's x
            // positions so SF Rounded's wider glyphs cannot collide.
            HStack(spacing: 2.4 * s) {
                Circle()
                    .fill(p.metric(.recovery(d.band), accent: true))
                    .frame(width: 5 * s, height: 5 * s)
                    .widgetAccentable(p.accents)
                Text("Recovery")
                    .font(whoopFont(7.5 * s, .semibold))
                    .foregroundStyle(p.fg2)
                RoundedRectangle(cornerRadius: 1 * s)
                    .fill(barColor)
                    .opacity(barOp)
                    .frame(width: 5 * s, height: 5.2 * s)
                    .padding(.leading, 2.6 * s)
                Text("Strain")
                    .font(whoopFont(7.5 * s, .semibold))
                    .foregroundStyle(p.fg2)
            }
            .lineLimit(1)
            .whoopAt(x: 170 * sx, baseline: 10 * s, anchor: 1)
            plot(d, p: p, s: s, sx: sx, barColor: barColor, barOp: barOp)
        }
    }

    @ViewBuilder
    private func plot(_ d: WhoopDisplay, p: WhoopPalette, s: CGFloat, sx: CGFloat, barColor: Color, barOp: Double) -> some View {
        let cw = 156 * sx
        let yb = 64 * s
        let hmax = 44 * s
        let slot = cw / 7
        let xs = (0..<7).map { slot * (CGFloat($0) + 0.5) }
        let ys = d.week.map { day in day.recovery.map { yb - CGFloat(min(max($0, 0), 100)) / 100 * hmax } }
        let radius = { (i: Int) in (i == 6 ? 3.1 : 2.4) * s }
        let holes = d.week.indices.compactMap { i in ys[i].map { (center: CGPoint(x: xs[i], y: $0), r: radius(i) + 1 * s) } }
        let holeMask = WhoopHoles(holes: holes).fill(style: FillStyle(eoFill: true))

        Path { path in
            path.move(to: CGPoint(x: 0, y: yb))
            path.addLine(to: CGPoint(x: cw, y: yb))
        }
        .stroke(p.fg, lineWidth: 0.6 * s)
        .opacity(0.25)
        Text("21")
            .font(whoopFont(6 * s, .semibold)).monospacedDigit()
            .foregroundStyle(p.fg2)
            .whoopAt(x: 170 * sx, baseline: yb - hmax + 2 * s, anchor: 1)
        Text("0")
            .font(whoopFont(6 * s, .semibold)).monospacedDigit()
            .foregroundStyle(p.fg2)
            .whoopAt(x: 170 * sx, baseline: yb + 1.5 * s, anchor: 1)

        if d.week.isEmpty {
            Text(d.noData ? "No data yet" : "No history yet")
                .font(whoopFont(7.5 * s, .semibold))
                .foregroundStyle(p.fg2)
                .whoopAt(x: cw / 2, baseline: 46 * s, anchor: 0.5)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(d.week) { day in
                    if let v = day.strain, v > 0 {
                        let h = CGFloat(min(v, 21) / 21) * hmax
                        RoundedRectangle(cornerRadius: min(1.5 * s, h / 2))
                            .fill(barColor)
                            .frame(width: 8 * s, height: h)
                            .position(x: xs[day.id], y: yb - h / 2)
                    }
                }
            }
            .opacity(barOp)
            .mask { holeMask }
            Path { path in
                // A missing day breaks the line.
                var pen = false
                for i in ys.indices {
                    guard let y = ys[i] else { pen = false; continue }
                    let pt = CGPoint(x: xs[i], y: y)
                    if pen { path.addLine(to: pt) } else { path.move(to: pt) }
                    pen = true
                }
            }
            .stroke(p.fg, style: StrokeStyle(lineWidth: 1.1 * s, lineJoin: .round))
            .opacity(0.55)
            .mask { holeMask }
            ForEach(d.week) { day in
                if let y = ys[day.id] {
                    Circle()
                        .fill(p.metric(.recovery(day.band), accent: true))
                        .frame(width: radius(day.id) * 2, height: radius(day.id) * 2)
                        .position(x: xs[day.id], y: y)
                        .widgetAccentable(p.accents)
                }
            }
            if let y = ys[6], let v = d.week[6].recovery {
                // Above the dot, held below the legend row near 100.
                Text("\(v)")
                    .font(whoopFont(7 * s)).monospacedDigit()
                    .foregroundStyle(p.fg)
                    .whoopAt(x: xs[6], baseline: max(y - 5.5 * s, 16.4 * s), anchor: 0.5)
            } else if d.recoveryPending {
                WhoopDots(cx: xs[6], cy: yb - 22 * s, r: 1 * s, gap: 3 * s, color: p.fg2)
            }
            ForEach(d.week) { day in
                Text(day.letter)
                    .font(whoopFont(6.5 * s, day.id == 6 ? .bold : .semibold))
                    .foregroundStyle(day.id == 6 ? p.fg : p.fg2)
                    .whoopAt(x: xs[day.id], baseline: 75.5 * s, anchor: 0.5)
            }
        }
    }
}

// MARK: - R9 Three Rings, R10 Three Rings + Detail

/// Recovery, strain and sleep as three rings across the slot, number inside
/// each. R9 puts a label in the metric color under each ring; R10 draws
/// smaller rings with one detail line under each instead.
struct WhoopThreeRingsView: View {
    let display: WhoopDisplay
    let tinted: Bool
    var detail = false
    @Environment(\.whoopAccentPreview) private var accentPreview

    var body: some View {
        if case .offline(let kind) = display.phase {
            WhoopOfflineRectangularView(kind: kind, tinted: tinted)
        } else {
            rings
        }
    }

    private struct Ring: Identifiable {
        let id: Int
        let label: String
        let metric: WhoopMetric
        let value: String
        let percent: Bool
        let frac: Double
        let detail: String
        let pending: Bool
        let note: String
    }

    private var data: [Ring] {
        let d = display
        return [
            Ring(id: 0, label: "RECOVERY", metric: .recovery(d.band),
                 value: d.recovery.map(String.init) ?? "--", percent: true,
                 frac: Double(d.recovery ?? 0) / 100,
                 detail: "HRV \(d.hrv.map(String.init) ?? "--")",
                 pending: d.recoveryPending, note: d.recoveryNote),
            Ring(id: 1, label: "STRAIN", metric: .strain,
                 value: String(format: "%.1f", d.strain), percent: false,
                 frac: d.strain / 21,
                 detail: d.kcal.map { "\($0.formatted(.number)) cal" } ?? "-- cal",
                 pending: false, note: ""),
            Ring(id: 2, label: "SLEEP", metric: .sleep,
                 value: d.sleepPct.map(String.init) ?? "--", percent: true,
                 frac: Double(d.sleepPct ?? 0) / 100,
                 detail: d.slept.map(WhoopDisplay.hm) ?? "--",
                 pending: d.sleepPending, note: d.sleepNote),
        ]
    }

    private var rings: some View {
        let d = display
        let p = WhoopPalette(tinted: tinted, stale: d.isStale, preview: accentPreview)
        let r: CGFloat = detail ? 22 : 24.5
        let w: CGFloat = detail ? 4.6 : 5
        let cy: CGFloat = detail ? 25.5 : 30
        let nsize: CGFloat = detail ? 13.5 : 15
        let ty: CGFloat = detail ? 67 : 71
        let items = data
        return WhoopCanvas(w: 170, h: 78, stretchX: true) { s, sx in
            ForEach(items) { ring in
                let cx = 170 / 6 * CGFloat(ring.id * 2 + 1) * sx
                let c = CGPoint(x: cx, y: cy * s)
                if ring.pending {
                    WhoopArc(center: c, radius: r * s, from: 0, to: 360)
                        .stroke(p.fg2, style: dottedStroke(2.3 * s, gap: 4.6 * s))
                    WhoopDots(cx: cx, cy: cy * s, r: 1.6 * s, gap: 4.8 * s, color: p.fg)
                } else {
                    let ac = p.metric(ring.metric, accent: true)
                    WhoopArc(center: c, radius: r * s, from: 0, to: 360)
                        .stroke(ac, lineWidth: w * s)
                        .opacity(0.3)
                        .widgetAccentable(p.accents)
                    WhoopArc(center: c, radius: r * s, from: 0, to: 360 * min(max(ring.frac, 0), 1))
                        .stroke(ac, style: roundStroke(w * s))
                        .widgetAccentable(p.accents)
                    valueText(ring, p: p, size: nsize * s)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: (2 * r - w - 4) * s)
                        .whoopAt(x: cx + (ring.percent && ring.value != "--" ? nsize * 0.17 * s : 0),
                                 baseline: (cy + nsize * 0.36) * s, anchor: 0.5)
                }
                if !d.isStale {
                    if detail {
                        Text(ring.pending ? ring.note : ring.detail)
                            .font(whoopFont(10 * s, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(ring.pending ? p.fg2 : p.fg)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: 55 * sx)
                            .whoopAt(x: cx, baseline: ty * s, anchor: 0.5)
                    } else {
                        Text(ring.label)
                            .font(whoopFont(7 * s))
                            .tracking(0.3 * s)
                            .foregroundStyle(tinted || ring.pending ? p.fg2 : p.metric(ring.metric))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: 55 * sx)
                            .whoopAt(x: cx, baseline: ty * s, anchor: 0.5)
                    }
                }
            }
            if d.isStale {
                WhoopSyncedLabel(text: d.ageLabel.map { "Synced \($0) ago" } ?? "No data yet",
                                 size: 8.5 * s, glyphR: 3.4 * s, color: p.fg2)
                    .whoopAt(x: 85 * sx, baseline: ty * s, anchor: 0.5)
            }
        }
    }

    private func valueText(_ ring: Ring, p: WhoopPalette, size: CGFloat) -> Text {
        let main = Text(ring.value)
            .font(whoopFont(size))
            .foregroundStyle(p.fg)
        guard ring.percent, ring.value != "--" else { return main.monospacedDigit() }
        return (main + Text("%").font(whoopFont(size * 0.5)).foregroundStyle(p.fg2)).monospacedDigit()
    }
}

// MARK: - Widget plumbing
// Everything above is plain SwiftUI so it can be rendered offscreen; the
// WidgetKit timeline, entry views and widget declarations follow.

struct WhoopEntry: TimelineEntry {
    let date: Date
    let summary: WhoopSummary?

    var display: WhoopDisplay { WhoopDisplay(summary: summary, now: date) }
}

enum WhoopRefreshPolicy {
    /// Next reload: 15 min from 05:00 to 23:00 local (day strain climbs and
    /// the morning recovery lands), 60 min overnight, and 60 min when the
    /// gateway's WHOOP auth is not ok. A failed fetch follows the same clock. The
    /// overnight hours keep the day inside watchOS's reload budget; opening
    /// AskClaude reloads on the spot without spending it.
    static func nextRefresh(now: Date, summary: WhoopSummary?, fetchOK: Bool, calendar: Calendar = .current) -> Date {
        let minutes: Double
        let hour = calendar.component(.hour, from: now)
        if let summary, fetchOK, summary.auth != .ok {
            minutes = 60
        } else if (5..<23).contains(hour) {
            minutes = 15
        } else {
            minutes = 60
        }
        return now.addingTimeInterval(minutes * 60)
    }

    /// Future entries at fetched_at + 60 min and hourly after, so the stale
    /// style and its age label show up even if no reload happens.
    static func staleEntries(for summary: WhoopSummary?, after now: Date) -> [WhoopEntry] {
        guard let summary, let fetched = summary.fetchedAtDate else { return [] }
        if summary.auth == .notConfigured || summary.auth == .reauthRequired { return [] }
        return (0..<6).compactMap { k in
            let date = fetched.addingTimeInterval(WhoopDisplay.staleAfter + Double(k) * 3600)
            return date > now ? WhoopEntry(date: date, summary: summary) : nil
        }
    }
}

struct WhoopProvider: TimelineProvider {
    func placeholder(in context: Context) -> WhoopEntry {
        WhoopEntry(date: Date(), summary: .sampleGreen())
    }

    func getSnapshot(in context: Context, completion: @escaping (WhoopEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task {
            let (summary, _) = await WhoopClient.load()
            completion(WhoopEntry(date: Date(), summary: summary))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WhoopEntry>) -> Void) {
        Task {
            let now = Date()
            let (summary, fetchOK) = await WhoopClient.load()
            let entries = [WhoopEntry(date: now, summary: summary)]
                + WhoopRefreshPolicy.staleEntries(for: summary, after: now)
            let next = WhoopRefreshPolicy.nextRefresh(now: now, summary: summary, fetchOK: fetchOK)
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }
}

private struct WhoopEntryView: View {
    enum Design { case rings, triad, strainToday, weekTrends, threeRingsDetail }

    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: WhoopEntry
    let design: Design

    var body: some View {
        let tinted = renderingMode == .accented
        Group {
            switch design {
            case .rings: WhoopRingsView(display: entry.display, tinted: tinted)
            case .triad: WhoopTriadView(display: entry.display, tinted: tinted)
            case .strainToday: WhoopStrainTodayView(display: entry.display, tinted: tinted)
            case .weekTrends: WhoopWeekTrendsView(display: entry.display, tinted: tinted)
            case .threeRingsDetail: WhoopThreeRingsView(display: entry.display, tinted: tinted, detail: true)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct WhoopRecoveryStrainRingsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WhoopWidgetKinds.recoveryStrainRings, provider: WhoopProvider()) { entry in
            WhoopEntryView(entry: entry, design: .rings)
        }
        .configurationDisplayName("Recovery + Strain")
        .description("WHOOP recovery ring around today's strain ring.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct WhoopTriadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WhoopWidgetKinds.triad, provider: WhoopProvider()) { entry in
            WhoopEntryView(entry: entry, design: .triad)
        }
        .configurationDisplayName("WHOOP Triad")
        .description("Recovery, strain and sleep as three arcs.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct WhoopStrainTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WhoopWidgetKinds.strainToday, provider: WhoopProvider()) { entry in
            WhoopEntryView(entry: entry, design: .strainToday)
        }
        .configurationDisplayName("Strain Today")
        .description("Day strain since you woke, with today's workouts.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct WhoopWeekTrendsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WhoopWidgetKinds.weekTrends, provider: WhoopProvider()) { entry in
            WhoopEntryView(entry: entry, design: .weekTrends)
        }
        .configurationDisplayName("WHOOP Week")
        .description("Seven days of strain against recovery.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct WhoopThreeRingsDetailWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WhoopWidgetKinds.threeRingsDetail, provider: WhoopProvider()) { entry in
            WhoopEntryView(entry: entry, design: .threeRingsDetail)
        }
        .configurationDisplayName("WHOOP Rings + Detail")
        .description("Three rings with HRV, calories and hours slept.")
        .supportedFamilies([.accessoryRectangular])
    }
}

// MARK: - Previews

private let previewNow = Date()

#Preview("Recovery + Strain", as: .accessoryCircular) {
    WhoopRecoveryStrainRingsWidget()
} timeline: {
    WhoopEntry(date: previewNow, summary: .sampleGreen(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .sampleRed(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .samplePending(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .sampleGreen(fetchedAt: previewNow.addingTimeInterval(-2 * 3600)))
    WhoopEntry(date: previewNow, summary: .sampleNotConfigured())
}

#Preview("Triad", as: .accessoryCircular) {
    WhoopTriadWidget()
} timeline: {
    WhoopEntry(date: previewNow, summary: .sampleGreen(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .sampleRed(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .samplePending(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .sampleGreen(fetchedAt: previewNow.addingTimeInterval(-2 * 3600)))
    WhoopEntry(date: previewNow, summary: .sampleNotConfigured())
}

#Preview("Strain Today", as: .accessoryRectangular) {
    WhoopStrainTodayWidget()
} timeline: {
    WhoopEntry(date: previewNow, summary: .sampleGreen(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .sampleRed(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .samplePending(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .sampleGreen(fetchedAt: previewNow.addingTimeInterval(-2 * 3600)))
    WhoopEntry(date: previewNow, summary: .sampleNotConfigured())
}

#Preview("Week", as: .accessoryRectangular) {
    WhoopWeekTrendsWidget()
} timeline: {
    WhoopEntry(date: previewNow, summary: .sampleGreen(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .sampleRed(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .samplePending(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .sampleGreen(fetchedAt: previewNow.addingTimeInterval(-2 * 3600)))
    WhoopEntry(date: previewNow, summary: .sampleNotConfigured())
}

#Preview("Rings + Detail", as: .accessoryRectangular) {
    WhoopThreeRingsDetailWidget()
} timeline: {
    WhoopEntry(date: previewNow, summary: .sampleGreen(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .sampleRed(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .samplePending(fetchedAt: previewNow))
    WhoopEntry(date: previewNow, summary: .sampleGreen(fetchedAt: previewNow.addingTimeInterval(-2 * 3600)))
    WhoopEntry(date: previewNow, summary: .sampleNotConfigured())
}
