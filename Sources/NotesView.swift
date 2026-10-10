import SwiftUI

/// Read-only browser for the Obsidian vault, served by the vault gateway's
/// note routes under the notes read token. Pinned notes first, then the
/// most recently modified, then a way into the folder tree; the search
/// field takes dictation or Scribble.
struct NotesView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = NotesStore()

    private var isSearching: Bool {
        !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The search's own error while searching; otherwise the recent list's,
    /// unless a cached list is showing with its own offline label.
    private var visibleError: String? {
        if isSearching { return store.searchError }
        return store.recentCachedAt == nil ? store.error : nil
    }

    var body: some View {
        List {
            TextField("Search notes", text: $store.query)

            if let error = visibleError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(store.recent.isEmpty && store.results.isEmpty ? .red : .orange)
            }

            if isSearching {
                Section("Results") {
                    if store.searching {
                        ProgressView()
                    } else if store.results.isEmpty {
                        Text("No matches.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.results) { note in
                        row(note)
                    }
                }
            } else {
                if !store.pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(store.pinned, id: \.self) { path in
                            row(VaultNote(path: path, name: VaultNote.displayName(for: path), mtime: nil))
                        }
                    }
                }
                Section {
                    if store.recent.isEmpty && !store.loading && store.error == nil {
                        Text("No notes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.recent) { note in
                        row(note)
                    }
                } header: {
                    Text("Recent")
                } footer: {
                    if let cachedAt = store.recentCachedAt {
                        OfflineLabel(prefix: store.recentStaleReason, cachedAt: cachedAt)
                    }
                }
                // One row into the folder tree keeps this page short.
                Section("Browse") {
                    NavigationLink {
                        FolderView(store: store, path: "")
                    } label: {
                        Label("All folders", systemImage: "folder.fill")
                            .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.loadRecent(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.loading)
            }
        }
        .overlay {
            if store.loading && store.recent.isEmpty && !isSearching { ProgressView() }
        }
        .onChange(of: store.query) { store.search() }
        .task { await store.loadRecent() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await store.loadRecent() } }
        }
    }

    private func row(_ note: VaultNote) -> some View {
        NavigationLink {
            NoteReaderView(store: store, path: note.path)
        } label: {
            NoteRow(note: note, pinned: store.isPinned(note.path))
        }
        .swipeActions {
            Button {
                store.togglePin(note.path)
            } label: {
                Image(systemName: store.isPinned(note.path) ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
    }
}

private struct NoteRow: View {
    let note: VaultNote
    let pinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                // Other text files keep their extension, so notes.json and
                // notes.md are told apart.
                Text(note.isMarkdown || note.fileExtension.isEmpty ? note.name : "\(note.name).\(note.fileExtension)")
                    .font(.footnote)
                    .lineLimit(2)
            }
            if !note.folder.isEmpty {
                Text(note.folder)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let modified = note.modified {
                Text(modified, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// "Offline, cached 2 hr ago": marks content served from the disk cache.
struct OfflineLabel: View {
    var prefix = "Offline, cached"
    let cachedAt: Date

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "icloud.slash")
            Text(prefix)
            Text(cachedAt, style: .relative)
            Text("ago")
        }
        .font(.system(size: 10))
        .foregroundStyle(.orange)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
