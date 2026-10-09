import Foundation
import UserNotifications
import WatchKit

/// Background long-poll against the bridge's GET /wait. Armed when the app
/// backgrounds while a turn is still running; the system completes the
/// download even with the app suspended, wakes us via a
/// WKURLSessionRefreshBackgroundTask, and we post a local notification with
/// the finished reply. Tapping it opens the app, which merges the stashed
/// reply (ChatStore.appDidActivate). No APNs involved.
final class TurnNotifier: NSObject {
    static let shared = TurnNotifier()
    static let sessionID = "dev.henryortega.askclaude.wait"
    private static let pendingReplyKey = "pendingBackgroundReply"
    private static let pendingSeqKey = "pendingBackgroundReplySeq"
    private static let pendingBootKey = "pendingBackgroundReplyBoot"
    /// Longer than the bridge's absolute turn ceiling (REPLY_BUDGET_S * 4),
    /// so one wait always spans the turn's whole lifetime and no re-arm
    /// logic is needed.
    private static let waitSeconds = 600

    private var session: URLSession?
    private var pendingRefreshTasks: [WKURLSessionRefreshBackgroundTask] = []

    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Arm a background wait for the turn sent at `since`. Replaces any
    /// previously armed wait. `cursor` (the last turn_seq seen, with its
    /// bridge boot) is the preferred key: `since` alone is skew-prone and
    /// can match the previous turn when the next one is sent within the
    /// slack, or never match at all.
    func arm(since: Date, cursor: TurnCursor.Value?) {
        // Same query builder as BridgeClient's `wait`, so the foreground
        // check-again poll and this background long-poll always agree.
        let path = BridgeClient.waitPath(
            since: since, afterSeq: cursor?.seq, bootID: cursor?.boot, timeout: Self.waitSeconds
        )
        guard let url = BridgeConfig.url(path) else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        let session = backgroundSession()
        // Resume synchronously: watchOS can suspend us before getAllTasks's
        // completion runs, which would silently drop the wait entirely.
        let task = session.downloadTask(with: req)
        task.resume()
        session.getAllTasks { tasks in
            tasks
                .filter { $0.taskIdentifier != task.taskIdentifier }
                .forEach { $0.cancel() }
        }
    }

    func cancelAll() {
        backgroundSession().getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    /// Relaunched by the system because the background session has events:
    /// recreating the session (same identifier) delivers them to our delegate.
    func handle(_ task: WKURLSessionRefreshBackgroundTask) {
        pendingRefreshTasks.append(task)
        _ = backgroundSession()
    }

    static func peekPendingReply() -> String? {
        UserDefaults.standard.string(forKey: pendingReplyKey)
    }

    /// The turn the stashed reply belongs to, when the bridge reported it.
    static func peekPendingReplyCursor() -> TurnCursor.Value? {
        let defaults = UserDefaults.standard
        guard
            let seq = defaults.object(forKey: pendingSeqKey) as? Int,
            let boot = defaults.string(forKey: pendingBootKey)
        else { return nil }
        return TurnCursor.Value(seq: seq, boot: boot)
    }

    static func clearPendingReply() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: pendingReplyKey)
        defaults.removeObject(forKey: pendingSeqKey)
        defaults.removeObject(forKey: pendingBootKey)
    }

    private func backgroundSession() -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = TimeInterval(Self.waitSeconds + 60)
        // /wait sends no bytes until the turn finishes; the default 60s
        // per-request idle timeout would kill any turn longer than a minute.
        config.timeoutIntervalForRequest = TimeInterval(Self.waitSeconds + 60)
        let created = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = created
        return created
    }
}

extension TurnNotifier: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard
            let data = try? Data(contentsOf: location),
            let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
            let reply = response.reply,
            !reply.isEmpty,
            response.partial != true
        else { return }
        let defaults = UserDefaults.standard
        defaults.set(reply, forKey: Self.pendingReplyKey)
        // Tag the stash with its turn so activation can drop one the app
        // already showed through the foreground /chat (see appDidActivate).
        if let seq = response.turn_seq, let boot = response.boot_id {
            defaults.set(seq, forKey: Self.pendingSeqKey)
            defaults.set(boot, forKey: Self.pendingBootKey)
        } else {
            defaults.removeObject(forKey: Self.pendingSeqKey)
            defaults.removeObject(forKey: Self.pendingBootKey)
        }
        let content = UNMutableNotificationContent()
        content.title = "Claude is done"
        content.body = String(reply.prefix(140))
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.pendingRefreshTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
            self.pendingRefreshTasks.removeAll()
        }
    }
}

/// The last bridge completion counter (turn_seq) the app has seen, with the
/// boot id of the bridge process that issued it. Persisted so a relaunch
/// mid-turn can still long-poll /wait by counter instead of by clock.
enum TurnCursor {
    struct Value: Equatable {
        let seq: Int
        let boot: String
    }

    private static let seqKey = "lastSeenTurnSeq"
    private static let bootKey = "bridgeBootID"

    static var current: Value? {
        let defaults = UserDefaults.standard
        guard
            let seq = defaults.object(forKey: seqKey) as? Int,
            let boot = defaults.string(forKey: bootKey)
        else { return nil }
        return Value(seq: seq, boot: boot)
    }

    /// Record the counter a bridge response carried: a 200's own turn, or
    /// the pre-turn value on a 202. Responses without both fields (older
    /// bridges, error bodies) leave the cursor alone.
    static func note(_ response: ChatResponse) {
        guard let seq = response.turn_seq, let boot = response.boot_id, !boot.isEmpty else { return }
        note(Value(seq: seq, boot: boot))
    }

    static func note(_ value: Value) {
        let defaults = UserDefaults.standard
        defaults.set(value.seq, forKey: seqKey)
        defaults.set(value.boot, forKey: bootKey)
    }

    /// Forget the cursor when the app can no longer tell which completions
    /// it has seen (a turn's fate is unknown); waits then fall back to the
    /// clock-based key until the next response re-seeds it.
    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: seqKey)
        defaults.removeObject(forKey: bootKey)
    }

    /// True when `value` is a completion the app has already seen.
    static func hasSeen(_ value: Value) -> Bool {
        guard let current else { return false }
        return current.boot == value.boot && value.seq <= current.seq
    }
}
