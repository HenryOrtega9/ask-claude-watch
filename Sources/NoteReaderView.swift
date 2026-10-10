import SwiftUI

/// One vault note, rendered read-only. A cached copy shows at once while the
/// live fetch runs; when the fetch fails the cached copy stays up with an
/// offline label instead of an error screen. Wikilinks resolve through the
/// gateway and push another reader.
struct NoteReaderView: View {
    @ObservedObject var store: NotesStore
    let path: String

    @State private var parsed: ParsedNote?
    /// The text `parsed` came from, so an unchanged live copy skips a reparse.
    @State private var shownText: String?
    @State private var fetchedAt: Date?
    /// Set while showing the cached copy because the live fetch failed.
    @State private var staleReason: String?
    @State private var error: String?
    @State private var linkStatus: String?
    @State private var pushedPath: String?
    /// The one link resolve in flight; a newer tap cancels it.
    @State private var linkTask: Task<Void, Never>?
    /// The path the state above belongs to. SwiftUI can hand this view a
    /// new `path` while keeping its @State.
    @State private var loadedPath: String?

    /// The Linked notes list is a large-target fallback for the inline
    /// links, capped so a link-dense note stays scrollable.
    private static let maxListedLinks = 30

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if let parsed {
                    if let staleReason, let fetchedAt {
                        OfflineLabel(prefix: staleReason, cachedAt: fetchedAt)
                    }
                    if let linkStatus {
                        Text(linkStatus)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(parsed.blocks) { block in
                        MarkdownBlockView(block: block)
                    }
                    if parsed.blocks.isEmpty {
                        Text("Empty note.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if parsed.truncated {
                        Text("Note truncated on watch")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                    if !parsed.links.isEmpty {
                        linkedNotes(parsed.links)
                    }
                } else if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task { await load() }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("Loading…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(VaultNote.displayName(for: path))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.togglePin(path)
                } label: {
                    Image(systemName: store.isPinned(path) ? "pin.fill" : "pin")
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let target = MarkdownBlocks.wikilinkTarget(from: url) else { return .systemAction }
            open(target)
            return .handled
        })
        .navigationDestination(item: $pushedPath) { next in
            // navigationDestination(item:) keeps the destination's identity
            // when the item changes; a new path needs fresh state.
            NoteReaderView(store: store, path: next).id(next)
        }
        .task(id: path) { await load() }
    }

    private func linkedNotes(_ links: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Linked notes")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(links.prefix(Self.maxListedLinks), id: \.self) { target in
                Button {
                    open(target)
                } label: {
                    Label(target, systemImage: "link")
                        .font(.footnote)
                        .foregroundStyle(.tint)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    private func load() async {
        if loadedPath != path {
            linkTask?.cancel()
            linkTask = nil
            parsed = nil
            shownText = nil
            fetchedAt = nil
            staleReason = nil
            error = nil
            linkStatus = nil
            loadedPath = path
        }
        if parsed == nil, let cached = await store.cachedNote(path) {
            await show(cached)
        }
        do {
            let fresh = try await store.fetchNote(path)
            guard loadedPath == path else { return }
            if fresh.text != shownText { await show(fresh) }
            fetchedAt = fresh.fetchedAt
            staleReason = nil
            error = nil
        } catch {
            // Leaving the page cancels the fetch; that is not an offline gateway.
            if Task.isCancelled || NotesStore.isCancellation(error) || loadedPath != path { return }
            if parsed != nil {
                staleReason = NotesStore.staleLabel(for: error)
            } else {
                self.error = NotesStore.message(for: error)
            }
        }
    }

    /// Parses off the main thread; a long note takes a moment on the watch.
    private func show(_ note: CachedNote) async {
        let text = note.text
        let notePath = path
        let cut = note.truncated ?? false
        let result = await Task.detached(priority: .userInitiated) {
            MarkdownBlocks.parse(text, path: notePath, sourceCut: cut)
        }.value
        guard loadedPath == notePath else { return }
        parsed = result
        shownText = text
        fetchedAt = note.fetchedAt
    }

    /// Resolves and pushes a wikilink. Only the latest tap may navigate: a
    /// slower resolve from an earlier tap is cancelled and its answer dropped.
    private func open(_ target: String) {
        linkTask?.cancel()
        linkStatus = "Opening \(target)…"
        linkTask = Task {
            do {
                let resolved = try await store.resolve(target, from: path)
                guard !Task.isCancelled else { return }
                if let resolved {
                    linkStatus = nil
                    pushedPath = resolved
                } else {
                    linkStatus = "No note named \(target)"
                }
            } catch {
                guard !Task.isCancelled, !NotesStore.isCancellation(error) else { return }
                linkStatus = NotesStore.message(for: error)
            }
        }
    }
}

/// Draws one parsed block. Inline styling and link tint come from the
/// AttributedString; this only picks fonts, indents and boxes.
struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(text)
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            Text(text)
                .font(.footnote)
        case .listItem(let marker, let level, let text, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(marker)
                    .font(.footnote)
                    .foregroundStyle(checked == true ? .green : .secondary)
                Text(text)
                    .font(.footnote)
                    .strikethrough(checked == true)
                    .foregroundStyle(checked == true ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(level) * 8)
        case .quote(let callout, let title, let lines):
            let tint = Self.calloutTint(callout)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tint)
                }
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index])
                        .font(.footnote)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.18))
            .overlay(alignment: .leading) {
                Rectangle().fill(tint).frame(width: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .code(_, let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
                .padding(.vertical, 2)
        case .placeholder(let label):
            Label(label, systemImage: label.hasPrefix("Table") ? "tablecells" : label == "Image" ? "photo" : "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        case 3: return .subheadline.weight(.semibold)
        default: return .footnote.weight(.semibold)
        }
    }

    /// Obsidian's callout families, roughly matching its default colors.
    private static func calloutTint(_ type: String?) -> Color {
        switch type {
        case nil, "quote", "cite": return .gray
        case "tip", "hint", "important": return .cyan
        case "success", "check", "done": return .green
        case "question", "help", "faq": return .yellow
        case "warning", "caution", "attention": return .orange
        case "failure", "fail", "missing", "danger", "error", "bug": return .red
        case "example": return .purple
        default: return .blue
        }
    }
}
