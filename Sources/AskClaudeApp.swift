import SwiftUI

@main
struct AskClaudeApp: App {
    @StateObject private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    ChatView()
                }
                NavigationStack {
                    SessionsView()
                }
                NavigationStack {
                    UsageView()
                }
            }
            .tabViewStyle(.verticalPage)
            .environmentObject(store)
        }
    }
}
