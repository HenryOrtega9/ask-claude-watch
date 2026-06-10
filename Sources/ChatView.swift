import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if store.messages.isEmpty && !store.isSending {
                        Text("Ask Claude about your Second Brain.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(store.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if store.isSending {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("Thinking…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                    if store.hasPartial && !store.isSending {
                        Button("Check for full reply") {
                            store.checkAgain()
                        }
                        .font(.footnote)
                    }
                    inputField
                }
            }
            .onChange(of: store.messages) {
                if let last = store.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: store.isSending) {
                if store.isSending {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active && store.hasPartial && !store.isSending {
                store.checkAgain()
            }
        }
        .navigationTitle("Ask Claude")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    store.newChat()
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .disabled(store.isSending)
            }
        }
    }

    private var inputField: some View {
        TextField("Ask…", text: $draft)
            .onSubmit {
                store.send(draft)
                draft = ""
            }
            .disabled(store.isSending)
            .padding(.top, 4)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 16) }
            VStack(alignment: .leading, spacing: 2) {
                Text(message.text)
                    .font(.footnote)
                if message.partial {
                    Text("partial")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if message.role != .user { Spacer(minLength: 16) }
        }
    }

    private var background: Color {
        switch message.role {
        case .user: return .blue.opacity(0.35)
        case .assistant: return .gray.opacity(0.25)
        case .error: return .red.opacity(0.3)
        }
    }
}
