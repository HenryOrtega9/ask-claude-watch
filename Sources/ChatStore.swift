import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class ChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isSending = false
    /// How many characters of each still-revealing message are visible.
    /// Purely transient (never persisted, never restored by `load`), so only
    /// a reply that lands live in this session ever types itself out.
    @Published private(set) var revealed: [UUID: Int] = [:]
    /// Follow-up the bridge suggests for the last completed turn, shown as a
    /// tappable chip until the user sends anything.
    @Published var suggestion: String?

    private let client = BridgeClient()
    private static let persistKey = "chatMessages"
    private static let maxPersisted = 50
    /// Reveal timer resolution; the per-tick chunk is derived from the
    /// configured rate, so this only sets how smooth the typing looks.
    private static let revealTick = 0.05
    /// A long reply is allowed to outrun the configured rate rather than
    /// trail the bridge by more than this.
    private static let maxRevealLag = 2.5

    /// When the in-flight turn's message was sent; drives the background
    /// /wait long-poll's `since` and clears once a complete reply lands.
    private var turnSentAt: Date?
    private var revealTask: Task<Void, Never>?
    private var revealLoopID = 0
    private var suggestTask: Task<Void, Never>?
    /// Bumped whenever a new turn starts (or the thread is reset), so a
    /// suggestion poll that resolves late can tell it is answering a
    /// superseded turn and drop its result.
    private var turnGeneration = 0

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

    // @AppStorage only writes a key once the user changes it, so an absent
    // key means "still on the default" rather than "off".
    private var animateRepliesEnabled: Bool {
        UserDefaults.standard.object(forKey: "animateReplies") as? Bool ?? true
    }

    private var animateCPS: Double {
        Double(max(10, UserDefaults.standard.object(forKey: "animateCPS") as? Int ?? 120))
    }

    private var suggestRepliesEnabled: Bool {
        UserDefaults.standard.object(forKey: "suggestReplies") as? Bool ?? true
    }

    /// What a bubble should draw right now: the whole text unless this
    /// message is mid-reveal.
    func displayText(for message: ChatMessage) -> String {
        guard let count = revealed[message.id], count < message.text.count else { return message.text }
        return String(message.text.prefix(count))
    }

    /// Start (or restart) the typewriter reveal for a reply that just landed.
    private func beginReveal(for id: UUID) {
        guard animateRepliesEnabled else { return }
        guard let message = messages.first(where: { $0.id == id }), !message.text.isEmpty else { return }
        revealed[id] = 0
        startRevealLoop()
    }

    private func startRevealLoop() {
        guard revealTask == nil else { return }
        revealLoopID &+= 1
        let loopID = revealLoopID
        revealTask = Task { @MainActor [weak self] in
            while let self, !self.revealed.isEmpty {
                try? await Task.sleep(for: .seconds(Self.revealTick))
                if Task.isCancelled { break }
                self.advanceReveal()
            }
            // Only retire the slot if it still belongs to this loop: a
            // cancelled loop can wake after a newer one already claimed it.
            if let self, self.revealLoopID == loopID { self.revealTask = nil }
        }
    }

    private func advanceReveal() {
        for (id, shown) in revealed {
            guard let message = messages.first(where: { $0.id == id }) else {
                revealed[id] = nil
                continue
            }
            let total = message.text.count
            guard shown < total else {
                revealed[id] = nil
                continue
            }
            // Never trail the finished reply by more than maxRevealLag, so a
            // long answer speeds up instead of crawling at the base rate.
            let backlog = Double(total - shown)
            let rate = max(animateCPS, backlog / Self.maxRevealLag)
            let step = max(1, Int((rate * Self.revealTick).rounded(.up)))
            let next = min(total, shown + step)
            revealed[id] = next == total ? nil : next
        }
    }

    /// Drop every in-progress reveal, showing the full text immediately.
    private func finishReveals() {
        revealTask?.cancel()
        revealTask = nil
        revealLoopID &+= 1
        if !revealed.isEmpty { revealed.removeAll() }
    }

    /// After a completed turn: adopt the suggestion the reply already carried,
    /// or long-poll /suggest for it once.
    private func noteSuggestion(from response: ChatResponse) {
        guard suggestRepliesEnabled else { return }
        guard let seq = response.turn_seq else { return }
        if let ready = Self.cleaned(response.suggestion) {
            suggestion = ready
            return
        }
        let generation = turnGeneration
        suggestTask?.cancel()
        suggestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.suggestTask = nil }
            // after_seq is the turn *before* this one, so the bridge treats
            // this turn's suggestion as the next thing it owes us.
            guard let response = try? await self.client.suggest(afterSeq: seq - 1, timeout: 40) else { return }
            // Drop it if a newer turn started, the user is mid-send, or the
            // bridge simply had nothing to offer.
            guard !Task.isCancelled, generation == self.turnGeneration, !self.isSending else { return }
            if let text = Self.cleaned(response.suggestion) { self.suggestion = text }
        }
    }

    private func clearSuggestion() {
        suggestTask?.cancel()
        suggestTask = nil
        suggestion = nil
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
        turnGeneration &+= 1
        clearSuggestion()
        finishReveals()
        // A stash from a previous turn must never be mistaken for this one.
        TurnNotifier.clearPendingReply()
        persist()
        Task {
            do {
                let response = try await client.chat(trimmed)
                let partial = response.partial == true
                let reply = response.reply ?? ""
                let message = ChatMessage(
                    role: .assistant,
                    text: reply.isEmpty ? "(empty reply)" : reply,
                    partial: partial
                )
                messages.append(message)
                if !partial {
                    turnSentAt = nil
                    TurnNotifier.clearPendingReply()
                    beginReveal(for: message.id)
                    noteSuggestion(from: response)
                }
            } catch let urlError as URLError where urlError.code == .timedOut || urlError.code == .networkConnectionLost {
                // The connection drops whenever the app suspends mid-turn; if
                // the background /wait already stashed the finished reply,
                // surface it instead of a partial.
                if let reply = TurnNotifier.peekPendingReply() {
                    TurnNotifier.clearPendingReply()
                    let message = ChatMessage(role: .assistant, text: reply)
                    messages.append(message)
                    beginReveal(for: message.id)
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
                    let message = ChatMessage(role: .assistant, text: reply)
                    messages.append(message)
                    beginReveal(for: message.id)
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
                        beginReveal(for: messages[index].id)
                    }
                    turnSentAt = nil
                    TurnNotifier.clearPendingReply()
                    noteSuggestion(from: response)
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
        // Nothing on screen to type out, and no point holding the suggest
        // long-poll open while suspended.
        finishReveals()
        suggestTask?.cancel()
        suggestTask = nil
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
            beginReveal(for: messages[index].id)
        } else {
            let message = ChatMessage(role: .assistant, text: reply)
            messages.append(message)
            beginReveal(for: message.id)
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
        turnGeneration &+= 1
        clearSuggestion()
        finishReveals()
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
