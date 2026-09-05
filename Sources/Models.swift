import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        case error
    }

    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
    var partial = false
}

struct ChatResponse: Decodable {
    var reply: String?
    var partial: Bool?
    var error: String?
    var session_id: String?
    var elapsed_ms: Int?
    /// Monotonic turn number the bridge assigns to a completed turn. Present
    /// on /wait and /last (and on /chat once the bridge that answered is new
    /// enough); absent on older bridges, which simply disables suggestions.
    var turn_seq: Int?
    /// A follow-up the user might want to send next, when the bridge already
    /// had it ready by the time the reply was handed over. Otherwise it is
    /// fetched separately through GET /suggest.
    var suggestion: String?
}

/// GET /suggest: 200 with a suggestion (or an explicit null when the bridge
/// decided there is nothing worth suggesting), 202 + error=wait_timeout when
/// the long-poll window expires first.
struct SuggestResponse: Decodable {
    var suggestion: String? = nil
    var turn_seq: Int? = nil
    var error: String? = nil
}

enum ClaudeModel: String, CaseIterable, Identifiable {
    case fable51 = "claude-fable-5-1"
    case fable
    case opus
    case sonnet
    case haiku

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fable51: return "Fable 5.1"
        case .fable: return "Fable 5"
        case .opus: return "Opus 4.8"
        case .sonnet: return "Sonnet 4.6"
        case .haiku: return "Haiku 4.5"
        }
    }

    /// Haiku is 200K-only; the others accept the [1m] long-context suffix.
    var supports1M: Bool { self != .haiku }

    func commandValue(oneMillion: Bool) -> String {
        oneMillion && supports1M ? "\(rawValue)[1m]" : rawValue
    }
}

enum EffortLevel: String, CaseIterable, Identifiable {
    case auto
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var label: String { rawValue == "xhigh" ? "x-high" : rawValue }

    /// xhigh is only accepted on Opus 1M and Fable 1M variants; everything
    /// else tops out at max.
    static func available(for model: ClaudeModel, oneMillion: Bool) -> [EffortLevel] {
        let xhighOK = oneMillion && (model == .opus || model == .fable || model == .fable51)
        return allCases.filter { $0 != .xhigh || xhighOK }
    }
}

struct BridgeSession: Decodable, Identifiable, Hashable {
    var id: String
    var kind: String
    var name: String
    var cwd: String
    var attach: String?
    var pid: Int?
    var last_activity: Int?
    var preview: String?

    /// Whether the bridge has an input route into this session (its own PTY
    /// child, or a tmux pane it can send-keys into). Otherwise view-only.
    var isAttachable: Bool { attach != nil }

    var kindIcon: String {
        switch kind {
        case "watch": return "applewatch"
        case "remote-control": return "antenna.radiowaves.left.and.right"
        default: return "terminal"
        }
    }

    var lastActivityDate: Date? {
        last_activity.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

struct SessionsResponse: Decodable {
    var sessions: [BridgeSession]
}

struct SessionMessage: Decodable, Identifiable, Hashable {
    var uuid: String?
    var role: String
    var text: String
    var ts: String?

    var id: String { uuid ?? "\(role)|\(ts ?? text)" }
}

struct SessionMessagesResponse: Decodable {
    var session: BridgeSession
    var messages: [SessionMessage]
}

struct UsageBucket: Decodable {
    var utilization: Double?
    var resets_at: String?

    var resetsAtDate: Date? { BridgeDates.parse(resets_at) }
}

struct UsageResponse: Decodable {
    var five_hour: UsageBucket?
    var seven_day: UsageBucket?
    var seven_day_opus: UsageBucket?
    var seven_day_sonnet: UsageBucket?
    var seven_day_omelette: UsageBucket?
    var extra_usage: ExtraUsage?
    /// Current OAuth usage shape: session/weekly caps, including any
    /// per-model weekly sub-cap (e.g. a Fable-scoped limit), superseding the
    /// legacy top-level buckets above when present.
    var limits: [LimitEntry]?

    struct ExtraUsage: Decodable {
        var is_enabled: Bool?
        var utilization: Double?
        var used_credits: Double?
        var monthly_limit: Double?
        var currency: String?
    }
}

struct LimitEntry: Decodable, Identifiable {
    var kind: String?
    var group: String?
    var percent: Double?
    var resets_at: String?
    var scope: Scope?

    struct Scope: Decodable {
        var model: ModelScope?
        struct ModelScope: Decodable {
            var display_name: String?
        }
    }

    var id: String { "\(kind ?? "")|\(scope?.model?.display_name ?? "")" }

    var displayLabel: String {
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "7-Day All"
        case "weekly_scoped":
            if let name = scope?.model?.display_name { return "7-Day \(name)" }
            return "7-Day"
        default:
            return kind?.capitalized ?? "Limit"
        }
    }
}

enum BridgeDates {
    /// The bridge relays timestamps in several ISO 8601 flavors (trailing Z,
    /// +00:00 offsets, microsecond fractions); try the strict parsers first
    /// and fall back to stripping a nonstandard fraction.
    static func parse(_ value: String?) -> Date? {
        guard var s = value, !s.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = fractional.date(from: s) ?? plain.date(from: s) { return d }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            s.removeSubrange(r)
            return plain.date(from: s)
        }
        return nil
    }
}

enum BridgeError: LocalizedError {
    case badURL
    case turnInFlight
    case notReady
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad bridge URL. Check Settings."
        case .turnInFlight: return "Claude is still working on the last question."
        case .notReady: return "Bridge session is not ready yet. Try again shortly."
        case .unauthorized: return "Bridge rejected the token. Check Settings."
        case .server(let message): return message
        }
    }
}
