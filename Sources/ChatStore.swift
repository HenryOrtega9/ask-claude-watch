import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class ChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isSending = false

    private let client = BridgeClient()
    private static let persistKey = "chatMessages"
    private static let maxPersisted = 50

    /// When the in-flight turn's message was sent; drives the background
    /// /wait long-poll's `since` and clears once a complete reply lands.
    private var turnSentAt: Date?

    init() {
        load()
        TurnNotifier.shared.requestAuthorization()
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
        turnSentAt = Date()
        // A stash from a previous turn must never be mistaken for this one.
        TurnNotifier.clearPendingReply()
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
                if !partial {
                    turnSentAt = nil
                    TurnNotifier.clearPendingReply()
                }
            } catch let urlError as URLError where urlError.code == .timedOut || urlError.code == .networkConnectionLost {
                // The connection drops whenever the app suspends mid-turn; if
                // the background /wait already stashed the finished reply,
                // surface it instead of a partial.
                if let reply = TurnNotifier.peekPendingReply() {
                    TurnNotifier.clearPendingReply()
                    messages.append(ChatMessage(role: .assistant, text: reply))
                    turnSentAt = nil
                } else {
                    messages.append(ChatMessage(role: .error, text: urlError.localizedDescription))
                    messages.append(ChatMessage(
                        role: .assistant,
                        text: "(connection dropped; the reply may still be coming)",
                        partial: true
                    ))
                }
            } catch {
                // Any other failure (e.g. the watch resumed on a different
                // network) can also mean the background /wait already has the
                // finished reply; surface it instead of an error.
                if let reply = TurnNotifier.peekPendingReply() {
                    TurnNotifier.clearPendingReply()
                    messages.append(ChatMessage(role: .assistant, text: reply))
                    turnSentAt = nil
                } else {
                    messages.append(ChatMessage(role: .error, text: error.localizedDescription))
                }
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
                    turnSentAt = nil
                    TurnNotifier.clearPendingReply()
                }
            } catch {
                messages.append(ChatMessage(role: .error, text: error.localizedDescription))
            }
            isSending = false
            persist()
        }
    }

    /// On backgrounding mid-turn: hand the wait to a background URLSession so
    /// a local notification fires when Claude finishes, wrist down or not.
    func appDidBackground() {
        guard isSending || hasPartial else { return }
        let since = turnSentAt
            ?? messages.last(where: { $0.role == .user })?.date
            ?? Date().addingTimeInterval(-60)
        TurnNotifier.shared.arm(since: since)
    }

    /// On activation: take over from any armed background wait and merge a
    /// reply it stashed while we were suspended.
    func appDidActivate() {
        TurnNotifier.shared.cancelAll()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        guard let reply = TurnNotifier.peekPendingReply() else { return }
        if let index = messages.lastIndex(where: { $0.partial }) {
            messages[index].text = reply
            messages[index].partial = false
        } else if !isSending {
            messages.append(ChatMessage(role: .assistant, text: reply))
        } else if isSending {
            // /chat is still resuming; its error path consumes the pending
            // reply when the dropped connection surfaces.
            return
        }
        TurnNotifier.clearPendingReply()
        turnSentAt = nil
        persist()
    }

    /// Fresh bridge session and a cleared thread.
    func newChat() {
        guard !isSending else { return }
        isSending = true
        turnSentAt = nil
        TurnNotifier.shared.cancelAll()
        TurnNotifier.clearPendingReply()
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
