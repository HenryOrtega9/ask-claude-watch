import SwiftUI

/// One vault folder, read-only: subfolders first, then the notes directly
/// inside. A cached listing shows at once while the live fetch runs; when
/// the fetch fails it stays up with an offline label, and the error view
/// shows only when this watch has never listed the folder.
struct FolderView: View {
    @ObservedObject var store: NotesStore
    /// Vault-relative; "" is the root.
    let path: String

    @State private var listing: FolderListing?
    @State private var fetchedAt: Date?
    /// Set while showing the cached listing because the live fetch failed.
    @State private var staleReason: String?
    @State private var error: String?
    /// The path the state above belongs to. SwiftUI can hand this view a
    /// new `path` while keeping its @State.
    @State private var loadedPath: String?
    /// Bumped by Retry so the fetch reruns inside the view's own task.
    @State private var attempt = 0

    private var title: String {
        path.split(separator: "/").last.map(String.init) ?? "Vault"
    }

    var body: some View {
        List {
            if let listing {
                if let staleReason, let fetchedAt {
                    OfflineLabel(prefix: staleReason, cachedAt: fetchedAt)
                }
                if listing.folders.isEmpty && listing.files.isEmpty {
                    Text("Empty folder.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(listing.folders) { folder in
                    NavigationLink {
                        FolderView(store: store, path: folder.path)
                    } label: {
                        FolderRow(folder: folder)
                    }
                }
                ForEach(listing.files) { note in
                    fileRow(note)
                }
            } else if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Retry") {
                    // Clearing the error shows Loading at once; the new task
                    // id cancels any earlier attempt.
                    self.error = nil
                    attempt += 1
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
        .navigationTitle(title)
        .task(id: "\(attempt)|\(path)") { await load() }
    }

    /// Opens and pins the same way the Notes page rows do.
    private func fileRow(_ note: VaultNote) -> some View {
        NavigationLink {
            NoteReaderView(store: store, path: note.path)
        } label: {
            FileRow(note: note, pinned: store.isPinned(note.path))
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

    private func load() async {
        if loadedPath != path {
            listing = nil
            fetchedAt = nil
            staleReason = nil
            error = nil
            loadedPath = path
        }
        if listing == nil, let cached = await store.cachedFolder(path), loadedPath == path {
            listing = cached.listing
            fetchedAt = cached.fetchedAt
        }
        do {
            let fresh = try await store.fetchFolder(path)
            guard loadedPath == path else { return }
            listing = fresh.listing
            fetchedAt = fresh.fetchedAt
            staleReason = nil
            error = nil
        } catch {
            // Leaving the page cancels the fetch; that is not an offline gateway.
            if Task.isCancelled || NotesStore.isCancellation(error) || loadedPath != path { return }
            if listing != nil {
                staleReason = NotesStore.staleLabel(for: error)
            } else if case NotesClientError.notFound = error {
                self.error = "Folder not found"
            } else {
                self.error = NotesStore.message(for: error)
            }
        }
    }
}

private struct FolderRow: View {
    let folder: VaultFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
                Text(folder.name)
                    .font(.footnote)
                    .lineLimit(2)
            }
            if let count = folder.notes {
                Text(count == 1 ? "1 note" : "\(count) notes")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FileRow: View {
    let note: VaultNote
    let pinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: pinned ? "pin.fill" : "doc.text")
                    .font(.system(size: pinned ? 9 : 11))
                    .foregroundStyle(pinned ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                // Other text files keep their extension, as on the Notes page.
                Text(note.isMarkdown || note.fileExtension.isEmpty ? note.name : "\(note.name).\(note.fileExtension)")
                    .font(.footnote)
                    .lineLimit(2)
            }
            if let modified = note.modified {
                Text(modified, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
