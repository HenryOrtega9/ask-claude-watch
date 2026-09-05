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
                        MessageBubble(message: message, text: store.displayText(for: message))
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
                    suggestionChip
                    inputField
                }
            }
            .onChange(of: store.messages) {
                if let last = store.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: store.revealed) {
                // Keep the growing bubble pinned to the bottom while it types
                // itself out. No animation: the scroll fires ~20x a second,
                // and animating each hop makes it stutter.
                guard !store.revealed.isEmpty, let last = store.messages.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
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

    /// Tappable follow-up the bridge proposed for the last turn. Hidden
    /// while a turn is in flight, and sent through the same path as typed
    /// input (which also clears it).
    @ViewBuilder
    private var suggestionChip: some View {
        if let suggestion = store.suggestion, !store.isSending {
            Button {
                store.send(suggestion)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 10))
                    Text(suggestion)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.22), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
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
    /// What to draw: the full body, or the prefix the store's typewriter
    /// reveal has uncovered so far.
    let text: String

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 16) }
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
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
