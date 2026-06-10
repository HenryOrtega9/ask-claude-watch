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
