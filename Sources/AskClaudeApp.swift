import SwiftUI
import WatchKit

/// Receives the system wake-up when the TurnNotifier's background /wait
/// download finishes while the app is suspended or not running.
final class ExtensionDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let urlTask = task as? WKURLSessionRefreshBackgroundTask,
               urlTask.sessionIdentifier == TurnNotifier.sessionID {
                TurnNotifier.shared.handle(urlTask)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

@main
struct AskClaudeApp: App {
    @WKApplicationDelegateAdaptor(ExtensionDelegate.self) private var delegate
    @StateObject private var store = ChatStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TabView {
                    ChatView()
                    SessionsView()
                    UsageView()
                }
                .tabViewStyle(.verticalPage)
            }
            .environmentObject(store)
            .onChange(of: scenePhase) {
                switch scenePhase {
                case .background:
                    store.appDidBackground()
                case .active:
                    store.appDidActivate()
                default:
                    break
                }
            }
        }
    }
}
