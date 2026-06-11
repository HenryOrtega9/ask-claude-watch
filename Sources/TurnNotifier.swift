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
    /// Slack subtracted from `since` to absorb watch/Mac clock skew. A stale
    /// match would need the PREVIOUS turn to have completed within this
    /// window of the new send, which the UI's single-turn flow rules out.
    private static let skewSlack: TimeInterval = 2
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
    /// previously armed wait.
    func arm(since: Date) {
        let sinceEpoch = Int(since.timeIntervalSince1970 - Self.skewSlack)
        guard let url = BridgeConfig.url("/wait?since=\(sinceEpoch)&timeout=\(Self.waitSeconds)") else { return }
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

    static func clearPendingReply() {
        UserDefaults.standard.removeObject(forKey: pendingReplyKey)
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
            response.partial != true
        else { return }
        UserDefaults.standard.set(reply, forKey: Self.pendingReplyKey)
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
