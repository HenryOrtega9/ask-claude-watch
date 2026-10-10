import Foundation

/// A note body as last fetched from the gateway.
struct CachedNote: Codable {
    let path: String
    let text: String
    let fetchedAt: Date
    /// The gateway sent only the head of the note. Optional so copies
    /// cached before the flag existed still decode.
    var truncated: Bool?
}

/// On-disk copies of the last 20 opened notes plus the last recent list,
/// as JSON in Application Support, so the Notes page still reads offline.
/// An actor so file writes stay off the main thread.
actor NoteDiskCache {
    static let maxNotes = 20

    private struct RecentList: Codable {
        let files: [VaultNote]
        let fetchedAt: Date
    }

    private let directory: URL
    private var notes: [CachedNote]?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("Notes", isDirectory: true)
    }

    private var notesFile: URL { directory.appendingPathComponent("notes.json") }
    private var recentFile: URL { directory.appendingPathComponent("recent.json") }

    /// Most recently fetched first.
    func all() -> [CachedNote] {
        if let notes { return notes }
        let loaded = (try? Data(contentsOf: notesFile)).flatMap { try? Self.decoder.decode([CachedNote].self, from: $0) } ?? []
        notes = loaded
        return loaded
    }

    func note(_ path: String) -> CachedNote? {
        all().first { $0.path == path }
    }

    /// Stores a fresh copy, keeping only what the reader can render (one
    /// past the cap, so a cut note still knows it was cut).
    @discardableResult
    func put(_ path: String, text: String, truncated: Bool = false) -> CachedNote {
        let entry = CachedNote(path: path, text: String(text.prefix(MarkdownBlocks.characterCap + 1)), fetchedAt: Date(), truncated: truncated)
        var list = all().filter { $0.path != path }
        list.insert(entry, at: 0)
        if list.count > Self.maxNotes { list.removeLast(list.count - Self.maxNotes) }
        notes = list
        write(list, to: notesFile)
        return entry
    }

    func recent() -> (files: [VaultNote], fetchedAt: Date)? {
        guard let data = try? Data(contentsOf: recentFile),
              let list = try? Self.decoder.decode(RecentList.self, from: data) else { return nil }
        return (list.files, list.fetchedAt)
    }

    func saveRecent(_ files: [VaultNote]) {
        write(RecentList(files: files, fetchedAt: Date()), to: recentFile)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("[AskClaude] note cache write failed: \(error)")
            #endif
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// State for the read-only Notes page: the recent list, search results and
/// pins, with the disk cache standing in whenever the gateway is out of
/// reach. Nothing here writes to the vault.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var recent: [VaultNote] = []
    /// When `recent` came from the disk cache instead of a live fetch.
    @Published private(set) var recentCachedAt: Date?
    /// Why the cached recent list is showing, for its offline label.
    @Published private(set) var recentStaleReason = "Offline, cached"
    @Published private(set) var results: [VaultNote] = []
    @Published private(set) var pinned: [String]
    @Published private(set) var loading = false
    @Published private(set) var searching = false
    /// Why the recent list failed to load live.
    @Published private(set) var error: String?
    /// Why the current search fell back to the notes this watch knows.
    /// Kept apart from `error` so it never lingers over the recent list.
    @Published private(set) var searchError: String?
    @Published var query = ""

    let cache = NoteDiskCache()
    private let client = NotesClient()
    private var searchTask: Task<Void, Never>?
    /// The trimmed query `results` belongs to.
    private var resultsQuery = ""
    private var lastRecentLoad: Date?
    private static let pinnedKey = "notesPinned"
    /// Paging through the TabView reappears this page often; a fresher
    /// list than this is kept unless the refresh button forces a reload.
    private static let recentTTL: TimeInterval = 60

    init() {
        pinned = UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? []
    }

    // MARK: Lists

    func loadRecent(force: Bool = false) async {
        if !force, recentCachedAt == nil, let last = lastRecentLoad, Date().timeIntervalSince(last) < Self.recentTTL {
            return
        }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let files = try await client.search("")
            recent = files
            recentCachedAt = nil
            lastRecentLoad = Date()
            error = nil
            await cache.saveRecent(files)
        } catch {
            // Paging away cancels the load; that is not an offline gateway.
            if Task.isCancelled || Self.isCancellation(error) { return }
            self.error = Self.message(for: error)
            recentStaleReason = Self.staleLabel(for: error)
            if let saved = await cache.recent() {
                // A list saved before attachments were filtered may hold them.
                recent = saved.files.filter(\.isReadable)
                recentCachedAt = saved.fetchedAt
            } else if recent.isEmpty {
                // No saved list yet: the notes opened on this watch are the
                // next best thing.
                let opened = await cache.all()
                recent = opened.map { VaultNote(path: $0.path, name: VaultNote.displayName(for: $0.path), mtime: nil) }
                recentCachedAt = opened.first?.fetchedAt
            }
        }
    }

    /// Runs the current query after a short settle, replacing any search
    /// still in flight. Offline, it filters the notes this watch knows.
    func search() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []
            resultsQuery = ""
            searching = false
            searchError = nil
            return
        }
        // Rows from another query must not stand in for this one's.
        if q != resultsQuery {
            results = []
            resultsQuery = q
            searchError = nil
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            defer { if !Task.isCancelled { searching = false } }
            do {
                let found = try await client.search(q)
                guard !Task.isCancelled else { return }
                results = found
                searchError = nil
            } catch {
                guard !Task.isCancelled, !Self.isCancellation(error) else { return }
                let known = await knownNotes()
                // The query can change while knownNotes() runs.
                guard !Task.isCancelled else { return }
                searchError = Self.message(for: error)
                results = known.filter {
                    $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q)
                }
            }
        }
    }

    // MARK: Pins

    func isPinned(_ path: String) -> Bool {
        pinned.contains(path)
    }

    func togglePin(_ path: String) {
        if let index = pinned.firstIndex(of: path) {
            pinned.remove(at: index)
        } else {
            pinned.append(path)
        }
        UserDefaults.standard.set(pinned, forKey: Self.pinnedKey)
    }

    // MARK: Notes

    func cachedNote(_ path: String) async -> CachedNote? {
        await cache.note(path)
    }

    /// Fetches a note live and refreshes its cached copy.
    func fetchNote(_ path: String) async throws -> CachedNote {
        let file = try await client.read(path)
        return await cache.put(path, text: file.text, truncated: file.truncated)
    }

    /// A wikilink target to a vault path. The gateway applies Obsidian's
    /// rules; when it cannot be reached, a case-insensitive basename match
    /// among the notes this watch knows (same folder first) stands in.
    /// nil when the gateway answers that nothing matches.
    func resolve(_ name: String, from: String) async throws -> String? {
        do {
            return try await client.resolve(name, from: from)
        } catch NotesClientError.tokenRejected {
            throw NotesClientError.tokenRejected
        } catch {
            let target = (name.split(separator: "#").first.map(String.init) ?? name).lowercased()
            let folder = (from as NSString).deletingLastPathComponent
            // Only files /file can serve; a PDF can share a note's basename.
            let matches = await knownNotes().filter {
                let path = $0.path.lowercased()
                return $0.isReadable && (path == target || path == target + ".md" || $0.name.lowercased() == target)
            }
            guard !matches.isEmpty else { throw error }
            // Same folder first, then .md over other text files that share
            // the basename, then the shortest path.
            func rank(_ note: VaultNote) -> (Int, Int, Int) {
                ((note.path as NSString).deletingLastPathComponent == folder ? 0 : 1, note.isMarkdown ? 0 : 1, note.path.count)
            }
            return matches.min { rank($0) < rank($1) }?.path
        }
    }

    /// Every readable note this watch has a row or a copy for, deduplicated
    /// by path.
    private func knownNotes() async -> [VaultNote] {
        var seen = Set<String>()
        var out: [VaultNote] = []
        let cached = await cache.all().map { VaultNote(path: $0.path, name: VaultNote.displayName(for: $0.path), mtime: nil) }
        let pins = pinned.map { VaultNote(path: $0, name: VaultNote.displayName(for: $0), mtime: nil) }
        for note in recent + results + cached + pins where note.isReadable && seen.insert(note.path).inserted {
            out.append(note)
        }
        return out
    }

    /// Prefix for the label on content served from the cache.
    static func staleLabel(for error: Error) -> String {
        switch error {
        case NotesClientError.tokenRejected: return "Token rejected, cached"
        case NotesClientError.notFound: return "Gone from vault, cached"
        default: return "Offline, cached"
        }
    }

    /// Structured-concurrency cancellation. URLSession's async API reports
    /// it as URLError(.cancelled), not CancellationError.
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return "Gateway unreachable"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
