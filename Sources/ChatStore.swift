import Foundation
import SwiftUI

@MainActor
final class ChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isSending = false

    private let client = BridgeClient()
    private static let persistKey = "chatMessages"
    private static let maxPersisted = 50

    init() {
        load()
        #if DEBUG
        Task {
            do {
                guard let url = BridgeConfig.url("/health") else { return }
                var req = URLRequest(url: url)
                req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
                let (data, _) = try await URLSession.shared.data(for: req)
                print("[AskClaude] bridge health: \(String(data: data, encoding: .utf8) ?? "?")")
            } catch {
                print("[AskClaude] bridge health FAILED: \(error)")
            }
        }
        #endif
    }

    var hasPartial: Bool {
        messages.contains(where: { $0.partial })
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        messages.append(ChatMessage(role: .user, text: trimmed))
        isSending = true
        persist()
        Task {
            do {
                let response = try await client.chat(trimmed)
                let partial = response.partial == true
                let reply = response.reply ?? ""
                messages.append(ChatMessage(
                    role: .assistant,
                    text: reply.isEmpty ? "(empty reply)" : reply,
                    partial: partial
                ))
            } catch let urlError as URLError where urlError.code == .timedOut || urlError.code == .networkConnectionLost {
                messages.append(ChatMessage(role: .error, text: urlError.localizedDescription))
                messages.append(ChatMessage(
                    role: .assistant,
                    text: "(connection dropped; the reply may still be coming)",
                    partial: true
                ))
            } catch {
                messages.append(ChatMessage(role: .error, text: error.localizedDescription))
            }
            isSending = false
            persist()
        }
    }

    /// After a partial (202) reply: fetch the completed answer from /last and
    /// replace the partial bubble when the bridge has finished the turn.
    func checkAgain() {
        guard !isSending else { return }
        isSending = true
        Task {
            do {
                let response = try await client.last()
                if let reply = response.reply, response.partial != true {
                    if let index = messages.lastIndex(where: { $0.partial }) {
                        messages[index].text = reply
                        messages[index].partial = false
                    } else {
                        messages.append(ChatMessage(role: .assistant, text: reply))
                    }
                }
            } catch {
                messages.append(ChatMessage(role: .error, text: error.localizedDescription))
            }
            isSending = false
            persist()
        }
    }

    /// Fresh bridge session and a cleared thread.
    func newChat() {
        guard !isSending else { return }
        isSending = true
        Task {
            do {
                _ = try await client.reset()
                messages.removeAll()
            } catch {
                messages.append(ChatMessage(role: .error, text: error.localizedDescription))
            }
            isSending = false
            persist()
        }
    }

    private func persist() {
        let tail = Array(messages.suffix(Self.maxPersisted))
        if let data = try? JSONEncoder().encode(tail) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.persistKey),
            let saved = try? JSONDecoder().decode([ChatMessage].self, from: data)
        else { return }
        messages = saved
    }
}
