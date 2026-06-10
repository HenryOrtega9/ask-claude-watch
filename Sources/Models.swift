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
}

enum ClaudeModel: String, CaseIterable, Identifiable {
    case fable
    case opus
    case sonnet
    case haiku

    var id: String { rawValue }

    var label: String {
        switch self {
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

    /// xhigh is only accepted on Opus 1M and Fable 5 1M; everything else
    /// tops out at max.
    static func available(for model: ClaudeModel, oneMillion: Bool) -> [EffortLevel] {
        let xhighOK = oneMillion && (model == .opus || model == .fable)
        return allCases.filter { $0 != .xhigh || xhighOK }
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
