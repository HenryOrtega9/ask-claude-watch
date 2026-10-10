import Foundation

/// Mirror of the vault gateway's `GET /whoop/summary` body (schema 1), as
/// built by daemons/gateway/src/whoop/summary.ts in claude-cli-chat. Field
/// names follow the wire format through explicit CodingKeys. Every enum has
/// an `unknown` fallback so a value the gateway adds later decodes instead
/// of failing the whole summary.
struct WhoopSummary: Codable, Equatable {
    var schema: Int
    var auth: WhoopAuth
    /// Gateway side: the last poll failed or the data is older than 45 min.
    var stale: Bool
    var fetchedAt: String?
    var updatedAt: String?
    var nextPollAt: String?
    var lastError: String?
    var recovery: Recovery
    var strain: Strain
    var sleep: Sleep
    var workout: Workout?
    /// Additive round-2 fields (still schema 1). Older gateways omit them,
    /// and a malformed value decodes as nil rather than failing the summary;
    /// see init(from:) below. Absent reads as empty.
    /// Last 7 cycles, oldest first; the last one is the current cycle.
    var week: [WeekDay]? = nil
    var strainToday: StrainToday? = nil
    /// Current cycle's workouts, oldest first.
    var workoutsToday: [WorkoutWindow]? = nil

    enum CodingKeys: String, CodingKey {
        case schema, auth, stale
        case fetchedAt = "fetched_at"
        case updatedAt = "updated_at"
        case nextPollAt = "next_poll_at"
        case lastError = "last_error"
        case recovery, strain, sleep, workout
        case week
        case strainToday = "strain_today"
        case workoutsToday = "workouts_today"
    }

    struct Recovery: Codable, Equatable {
        var state: WhoopRecordState
        /// False while today's recovery is pending or absent and the gateway
        /// is showing the previous cycle's score instead.
        var isCurrentCycle: Bool
        var score: Int?
        var band: WhoopBand?
        var hrvMs: Double?
        var rhrBpm: Int?
        var spo2Pct: Double?
        var skinTempC: Double?
        var calibrating: Bool
        var updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case state
            case isCurrentCycle = "is_current_cycle"
            case score, band
            case hrvMs = "hrv_ms"
            case rhrBpm = "rhr_bpm"
            case spo2Pct = "spo2_pct"
            case skinTempC = "skin_temp_c"
            case calibrating
            case updatedAt = "updated_at"
        }
    }

    struct Strain: Codable, Equatable {
        var state: WhoopRecordState
        var dayStrain: Double?
        var kilojoule: Double?
        var kcal: Int?
        var avgHrBpm: Int?
        var maxHrBpm: Int?
        var cycleStart: String?
        var cycleEnd: String?

        enum CodingKeys: String, CodingKey {
            case state
            case dayStrain = "day_strain"
            case kilojoule, kcal
            case avgHrBpm = "avg_hr_bpm"
            case maxHrBpm = "max_hr_bpm"
            case cycleStart = "cycle_start"
            case cycleEnd = "cycle_end"
        }
    }

    struct Sleep: Codable, Equatable {
        var state: WhoopRecordState
        var performancePct: Int?
        var hoursSlept: Double?
        var hoursNeeded: Double?
        var hoursInBed: Double?
        var efficiencyPct: Double?
        var consistencyPct: Double?
        var respiratoryRate: Double?
        var stages: Stages?
        var disturbances: Int?
        var start: String?
        var end: String?

        enum CodingKeys: String, CodingKey {
            case state
            case performancePct = "performance_pct"
            case hoursSlept = "hours_slept"
            case hoursNeeded = "hours_needed"
            case hoursInBed = "hours_in_bed"
            case efficiencyPct = "efficiency_pct"
            case consistencyPct = "consistency_pct"
            case respiratoryRate = "respiratory_rate"
            case stages, disturbances, start, end
        }
    }

    struct Stages: Codable, Equatable {
        var lightH: Double
        var swsH: Double
        var remH: Double
        var awakeH: Double

        enum CodingKeys: String, CodingKey {
            case lightH = "light_h"
            case swsH = "sws_h"
            case remH = "rem_h"
            case awakeH = "awake_h"
        }
    }

    struct Workout: Codable, Equatable {
        var state: WhoopRecordState
        var sport: String
        var strain: Double?
        var kcal: Int?
        var avgHrBpm: Int?
        var maxHrBpm: Int?
        var start: String
        var end: String

        enum CodingKeys: String, CodingKey {
            case state, sport, strain, kcal
            case avgHrBpm = "avg_hr_bpm"
            case maxHrBpm = "max_hr_bpm"
            case start, end
        }
    }

    /// One cycle of the 7-day history. `day` is the cycle's local date
    /// (YYYY-MM-DD).
    struct WeekDay: Codable, Equatable {
        var cycleStart: String?
        var day: String?
        var recovery: Int?
        var band: WhoopBand?
        var strain: Double?

        enum CodingKeys: String, CodingKey {
            case cycleStart = "cycle_start"
            case day, recovery, band, strain
        }
    }

    /// The Mac mini's own step series of the current cycle's day strain: a
    /// point only when the strain changed.
    struct StrainToday: Codable, Equatable {
        var cycleStart: String?
        var wake: String?
        var points: [StrainPoint]?

        enum CodingKeys: String, CodingKey {
            case cycleStart = "cycle_start"
            case wake, points
        }
    }

    struct StrainPoint: Codable, Equatable {
        var t: String
        var strain: Double
    }

    struct WorkoutWindow: Codable, Equatable {
        var sport: String
        var start: String
        var end: String
        var strain: Double?
    }
}

extension WhoopSummary {
    /// Hand-written so the round-2 fields stay optional and lenient: a
    /// gateway that sends a shape this build does not expect still yields
    /// the core summary. Lives in an extension so the memberwise init stays.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        auth = try c.decode(WhoopAuth.self, forKey: .auth)
        stale = try c.decode(Bool.self, forKey: .stale)
        fetchedAt = try c.decodeIfPresent(String.self, forKey: .fetchedAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        nextPollAt = try c.decodeIfPresent(String.self, forKey: .nextPollAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        recovery = try c.decode(Recovery.self, forKey: .recovery)
        strain = try c.decode(Strain.self, forKey: .strain)
        sleep = try c.decode(Sleep.self, forKey: .sleep)
        workout = try c.decodeIfPresent(Workout.self, forKey: .workout)
        week = (try? c.decodeIfPresent([WeekDay].self, forKey: .week)) ?? nil
        strainToday = (try? c.decodeIfPresent(StrainToday.self, forKey: .strainToday)) ?? nil
        workoutsToday = (try? c.decodeIfPresent([WorkoutWindow].self, forKey: .workoutsToday)) ?? nil
    }
}

/// String-backed enum that decodes an unrecognized value as `unknown`
/// instead of throwing.
protocol WhoopLenientEnum: RawRepresentable, Codable where RawValue == String {
    static var unknown: Self { get }
}

extension WhoopLenientEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum WhoopAuth: String, WhoopLenientEnum {
    case ok
    case notConfigured = "not_configured"
    case reauthRequired = "reauth_required"
    case error
    case unknown
}

enum WhoopRecordState: String, WhoopLenientEnum {
    case scored, pending, unscorable, missing, unknown
}

enum WhoopBand: String, WhoopLenientEnum {
    case green, yellow, red, unknown

    /// WHOOP's published bands: green 67 to 100, yellow 34 to 66, red 0 to 33.
    static func forScore(_ score: Int) -> WhoopBand {
        if score >= 67 { return .green }
        if score >= 34 { return .yellow }
        return .red
    }
}

// MARK: - Dates and derived values

enum WhoopDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return fractional.date(from: s) ?? whole.date(from: s)
    }

    static func string(_ d: Date) -> String {
        fractional.string(from: d)
    }

    /// Calendar dates as the gateway writes `week[].day`. The strings are
    /// already local dates, so the math runs in UTC: a fixed zone cannot
    /// drift from the caller's calendar when the watch changes time zone
    /// while this process is alive. Pair it with `calendar` below.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Gregorian in UTC, for day arithmetic and weekdays on parseDay results.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// UTC midnight of the given calendar date, or nil.
    static func parseDay(_ s: String?) -> Date? {
        guard let s else { return nil }
        return dayFormatter.date(from: s)
    }

    static func dayString(_ d: Date) -> String {
        dayFormatter.string(from: d)
    }
}

extension WhoopSummary {
    static func decode(_ data: Data) throws -> WhoopSummary {
        try JSONDecoder().decode(WhoopSummary.self, from: data)
    }

    var fetchedAtDate: Date? { WhoopDate.parse(fetchedAt) }

    /// Today's recovery is scored. Mirrors the gateway's own
    /// `recoveryScoredToday` test: a score carried over from the previous
    /// cycle does not count.
    var recoveryScoredToday: Bool {
        recovery.state == .scored && recovery.isCurrentCycle && recovery.score != nil
    }
}

// MARK: - Sample data (placeholder, snapshots, previews)

extension WhoopSummary {
    /// Builds a scored, fresh summary. Hours are decimal like the wire format
    /// (7h 12m is 7.2).
    static func sample(
        recovery: Int, hrv: Double, rhr: Int,
        strain: Double, kcal: Int,
        sleepPct: Int, slept: Double, needed: Double,
        fetchedAt: Date = Date()
    ) -> WhoopSummary {
        let stamp = WhoopDate.string(fetchedAt)
        return WhoopSummary(
            schema: 1, auth: .ok, stale: false,
            fetchedAt: stamp, updatedAt: stamp, nextPollAt: nil, lastError: nil,
            recovery: Recovery(
                state: .scored, isCurrentCycle: true, score: recovery,
                band: .forScore(recovery), hrvMs: hrv, rhrBpm: rhr,
                spo2Pct: 96, skinTempC: 33.4, calibrating: false, updatedAt: stamp
            ),
            strain: Strain(
                state: .scored, dayStrain: strain, kilojoule: Double(kcal) * 4.184, kcal: kcal,
                avgHrBpm: 74, maxHrBpm: 162, cycleStart: nil, cycleEnd: nil
            ),
            sleep: Sleep(
                state: .scored, performancePct: sleepPct, hoursSlept: slept, hoursNeeded: needed,
                hoursInBed: slept + 0.5, efficiencyPct: 92, consistencyPct: 80, respiratoryRate: 15.2,
                stages: nil, disturbances: 6, start: nil, end: nil
            ),
            workout: nil
        )
    }

    /// Fills the round-2 series. Times are minutes before `fetchedAt`, so a
    /// sample fetched at 9:41 AM reproduces the gallery's clock times. The
    /// week ends on fetchedAt's local date (Fri 9 Oct 2026 gives Sat 3 Oct
    /// to Fri 9 Oct).
    mutating func setSeries(
        weekRecovery: [Int?], weekStrain: [Double?],
        wakeAgo: Double?, points: [(ago: Double, strain: Double)],
        workouts: [(sport: String, startAgo: Double, endAgo: Double, strain: Double)]
    ) {
        let fetched = fetchedAtDate ?? Date()
        let at = { (ago: Double) in WhoopDate.string(fetched.addingTimeInterval(-ago * 60)) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.startOfDay(for: fetched)
        let n = weekRecovery.count
        week = (0..<n).map { i in
            let date = cal.date(byAdding: .day, value: i - (n - 1), to: today) ?? today
            let rec = weekRecovery[i]
            // The local date, written like the gateway does; dayString works
            // in UTC and would shift a day east of Greenwich.
            let ymd = cal.dateComponents([.year, .month, .day], from: date)
            return WeekDay(
                cycleStart: WhoopDate.string(date.addingTimeInterval(6 * 3600)),
                day: String(format: "%04d-%02d-%02d", ymd.year ?? 0, ymd.month ?? 0, ymd.day ?? 0), recovery: rec,
                band: rec.map(WhoopBand.forScore), strain: i < weekStrain.count ? weekStrain[i] : nil
            )
        }
        strainToday = StrainToday(
            cycleStart: wakeAgo.map(at), wake: wakeAgo.map(at),
            points: points.map { StrainPoint(t: at($0.ago), strain: $0.strain) }
        )
        workoutsToday = workouts.map {
            WorkoutWindow(sport: $0.sport, start: at($0.startAgo), end: at($0.endAgo), strain: $0.strain)
        }
        strain.cycleStart = strainToday?.cycleStart
    }

    /// The design gallery's green day: 72%, HRV 68, RHR 52, strain 11.4,
    /// 1,846 cal, sleep 88% (7h 12m of 8h 05m). Fetched at 9:41 AM it woke
    /// at 5:55 and ran from 6:40 to 7:22.
    static func sampleGreen(fetchedAt: Date = Date()) -> WhoopSummary {
        var s = sample(recovery: 72, hrv: 68, rhr: 52, strain: 11.4, kcal: 1846,
                       sleepPct: 88, slept: 7.2, needed: 8.08, fetchedAt: fetchedAt)
        s.setSeries(
            weekRecovery: [54, 61, 38, 77, 83, 66, 72],
            weekStrain: [13.0, 17.6, 6.2, 8.4, 15.9, 12.1, 11.4],
            wakeAgo: 226,
            points: [(226, 0.0), (181, 1.6), (139, 10.2), (71, 10.9), (1, 11.4)],
            workouts: [("Running", 181, 139, 9.8)]
        )
        return s
    }

    /// The red day: 24%, HRV 38, RHR 61, strain 4.2, 1,212 cal, sleep 61%
    /// (5h 48m of 8h 20m). Fetched at 9:41 AM it woke at 6:50 and walked
    /// from 7:05 to 7:35.
    static func sampleRed(fetchedAt: Date = Date()) -> WhoopSummary {
        var s = sample(recovery: 24, hrv: 38, rhr: 61, strain: 4.2, kcal: 1212,
                       sleepPct: 61, slept: 5.8, needed: 8.33, fetchedAt: fetchedAt)
        s.setSeries(
            weekRecovery: [41, 35, 52, 28, 30, 44, 24],
            weekStrain: [16.4, 7.9, 17.8, 14.6, 8.8, 18.3, 4.2],
            wakeAgo: 171,
            points: [(171, 0.0), (156, 0.5), (126, 3.5), (1, 4.2)],
            workouts: [("Walking", 156, 126, 3.1)]
        )
        return s
    }

    /// Early morning: the night is not scored yet, so the gateway carries the
    /// previous cycle's recovery (is_current_cycle false) and sleep is
    /// pending. Strain is live and low.
    static func samplePending(fetchedAt: Date = Date()) -> WhoopSummary {
        var s = sampleGreen(fetchedAt: fetchedAt)
        s.recovery.isCurrentCycle = false
        s.strain.dayStrain = 0.4
        s.strain.kcal = 142
        // Today has no recovery yet and the strain series has not started.
        s.week?[6].recovery = nil
        s.week?[6].band = nil
        s.week?[6].strain = 0.4
        s.strainToday = StrainToday(cycleStart: nil, wake: nil, points: [])
        s.workoutsToday = []
        s.strain.cycleStart = nil
        s.sleep = Sleep(
            state: .pending, performancePct: nil, hoursSlept: nil, hoursNeeded: nil,
            hoursInBed: nil, efficiencyPct: nil, consistencyPct: nil, respiratoryRate: nil,
            stages: nil, disturbances: nil, start: nil, end: nil
        )
        return s
    }

    /// No WHOOP app registered on the gateway yet.
    static func sampleNotConfigured() -> WhoopSummary {
        var s = sampleGreen()
        s.auth = .notConfigured
        s.stale = true
        s.fetchedAt = nil
        return s
    }
}

/// Widget kinds, shared so the app can reload the WHOOP complications when it
/// opens (a foreground reload does not count against the widget budget).
enum WhoopWidgetKinds {
    static let recoveryStrainRings = "WhoopRecoveryStrainRings"
    static let triad = "WhoopTriad"
    static let strainToday = "WhoopStrainToday"
    static let weekTrends = "WhoopWeekTrends"
    static let threeRingsDetail = "WhoopThreeRingsDetail"
    static let twinRings = "WhoopTwinRings"
    static let splitGauges = "WhoopSplitGauges"
    static let all = [recoveryStrainRings, triad, strainToday, weekTrends, threeRingsDetail, twinRings, splitGauges]
}
