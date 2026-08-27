import SwiftUI

/// Lists the Mac's activated Remote Control sessions (the bridge returns only
/// `claude remote-control` sessions; plain terminal sessions and the plugin's
/// own chat subprocesses are excluded) and opens each as a polled transcript
/// view.
struct SessionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sessions: [BridgeSession] = []
    @State private var error: String?
    @State private var loading = false

    private let client = BridgeClient()

    var body: some View {
        List {
            if let error, sessions.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if sessions.isEmpty && error == nil && !loading {
                Text("No active sessions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                NavigationLink {
                    SessionChatView(session: session)
                } label: {
                    SessionRow(session: session)
                }
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .overlay {
            if loading && sessions.isEmpty { ProgressView() }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            sessions = try await client.sessions()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SessionRow: View {
    let session: BridgeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: session.kindIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(session.isAttachable ? .green : .secondary)
                Text(session.name)
                    .font(.footnote)
                    .lineLimit(1)
            }
            if let preview = session.preview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let date = session.lastActivityDate {
                Text(date, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Live transcript of one session, refreshed every few seconds. Sessions the
/// bridge can reach (its own PTY or a tmux pane) also get an input field;
/// replies arrive through the poll, so messages sent from claude.ai or the
/// Mac show up here too.
struct SessionChatView: View {
    let session: BridgeSession

    @Environment(\.scenePhase) private var scenePhase
    @State private var info: BridgeSession?
    @State private var messages: [SessionMessage] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?
    /// Send failures live separately so the polling loop's load() cannot
    /// erase them before the user sees them.
    @State private var sendError: String?

    private let client = BridgeClient()

    private var current: BridgeSession { info ?? session }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if messages.isEmpty {
                        Text(error ?? "No messages yet.")
                            .font(.footnote)
                            .foregroundStyle(error == nil ? .secondary : Color.red)
                            .padding(.top, 8)
                    }
                    ForEach(messages) { message in
                        SessionBubble(message: message)
                            .id(message.id)
                    }
                    if sending {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("Sending…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if current.isAttachable {
                        TextField("Message…", text: $draft)
                            .onSubmit { send() }
                            .disabled(sending)
                            .padding(.top, 4)
                        if let sendError {
                            Text(sendError)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("View only")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                }
            }
            .onChange(of: messages) {
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .navigationTitle(current.name)
        .task {
            // Only poll while frontmost: SwiftUI does not cancel `.task` on
            // background/inactive, so without this gate the loop would keep
            // waking the radio every few seconds with the screen off. Back
            // off on repeated failures (dead bridge, off the tailnet) so an
            // unreachable Mac doesn't cost a request every 3s indefinitely.
            var backoffSeconds = 3.0
            while !Task.isCancelled {
                if scenePhase == .active {
                    let ok = await load()
                    backoffSeconds = ok ? 3.0 : min(backoffSeconds * 2, 30.0)
                    try? await Task.sleep(for: .seconds(backoffSeconds))
                } else {
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    @discardableResult
    private func load() async -> Bool {
        do {
            let response = try await client.sessionMessages(id: current.id)
            info = response.session
            messages = response.messages
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        sending = true
        Task {
            do {
                try await client.sessionSend(id: current.id, message: trimmed)
                draft = ""
                sendError = nil
            } catch {
                sendError = error.localizedDescription
            }
            sending = false
            await load()
        }
    }
}

private struct SessionBubble: View {
    let message: SessionMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 16) }
            Text(message.text)
                .font(.footnote)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(message.role == "user" ? Color.blue.opacity(0.35) : Color.gray.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if message.role != "user" { Spacer(minLength: 16) }
        }
    }
}
