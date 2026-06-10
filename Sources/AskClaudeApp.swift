import SwiftUI

@main
struct AskClaudeApp: App {
    @StateObject private var store = ChatStore()

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
        }
    }
}
