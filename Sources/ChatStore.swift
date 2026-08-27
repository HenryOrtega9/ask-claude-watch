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
        // A leftover partial bubble from an earlier, still-unresolved turn
        // must never be mistaken for this turn's reply by checkAgain or
        // appDidActivate — demote it before this turn's own partial (if any)
        // can appear.
        if let staleIndex = messages.lastIndex(where: { $0.partial }) {
            messages[staleIndex].partial = false
        }
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

    /// After a partial (202) reply: long-poll /wait for the turn this partial
    /// bubble belongs to (never /last, whose single unscoped slot holds
    /// whichever turn finished most recently and could be a stale answer to
    /// an earlier question). A 202 timeout means Claude is still working, so
    /// the partial bubble is left untouched.
    func checkAgain() {
        guard !isSending else { return }
        isSending = true
        let since = turnSentAt
            ?? messages.last(where: { $0.partial })?.date
            ?? Date().addingTimeInterval(-60)
        Task {
            do {
                let response = try await client.wait(since: since, timeout: 20)
                if let reply = response.reply, response.partial != true {
                    // Merge into the partial bubble this turn owns. If it is
                    // already gone (e.g. appDidActivate resolved it first),
                    // there is nothing to append — doing so would duplicate
                    // a reply already shown.
                    if let index = messages.lastIndex(where: { $0.partial }) {
                        messages[index].text = reply.isEmpty ? "(empty reply)" : reply
                        messages[index].partial = false
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
        // Never fall back to the newest user message's date: with multiple
        // turns in history that message may belong to an already-completed
        // turn, not the one this partial bubble is still waiting on. The
        // partial bubble's own timestamp is scoped to its turn regardless.
        let since = turnSentAt
            ?? messages.last(where: { $0.partial })?.date
            ?? Date().addingTimeInterval(-60)
        TurnNotifier.shared.arm(since: since)
    }

    /// On activation: take over from any armed background wait and merge a
    /// reply it stashed while we were suspended.
    func appDidActivate() {
        TurnNotifier.shared.cancelAll()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        guard let reply = TurnNotifier.peekPendingReply() else { return }
        if isSending {
            // /chat is still resuming; its error path consumes the pending
            // reply when the dropped connection surfaces. Checking this
            // first (before touching `messages`) keeps that path the sole
            // owner of the merge for the in-flight turn.
            return
        }
        // Scope the partial lookup to this turn: a bubble from an earlier,
        // already-superseded turn must never be targeted.
        let turnStart = messages.lastIndex(where: { $0.role == .user }) ?? messages.startIndex
        if let index = messages[turnStart...].lastIndex(where: { $0.partial }) {
            messages[index].text = reply
            messages[index].partial = false
        } else {
            messages.append(ChatMessage(role: .assistant, text: reply))
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
        // Cap in-memory history too: a relaunch already only ever restores
        // the last maxPersisted messages, so trimming here just keeps a
        // long-running session's memory and diffing cost from growing
        // without bound instead of only capping what gets saved to disk.
        if messages.count > Self.maxPersisted {
            messages.removeFirst(messages.count - Self.maxPersisted)
        }
        // Encode off the main actor: this runs on every send and every
        // reply, and re-encoding up to maxPersisted full message bodies
        // synchronously here would otherwise compete with the UI. Capture
        // the key as a local (rather than the actor-isolated static) so the
        // detached task never touches actor-isolated state.
        let snapshot = messages
        let key = Self.persistKey
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: key)
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
