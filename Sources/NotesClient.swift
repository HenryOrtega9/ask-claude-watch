import Foundation

enum NotesClientError: LocalizedError {
    case badURL
    case tokenRejected
    case notFound
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad gateway URL"
        case .tokenRejected: return "Notes token rejected. Check Settings."
        case .notFound: return "Note not found"
        case .http(413): return "Too large to read on the watch"
        case .http(415): return "Not a text file"
        case .http(let status): return "Gateway HTTP \(status)"
        }
    }
}

/// One row of the gateway's GET /files listing. `mtime` is epoch
/// milliseconds.
struct VaultNote: Codable, Identifiable, Hashable {
    let path: String
    let name: String
    let mtime: Double?

    var id: String { path }

    var folder: String {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }

    var modified: Date? {
        mtime.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Lowercased extension without the dot; `name` drops it.
    var fileExtension: String {
        (path as NSString).pathExtension.lowercased()
    }

    /// The gateway's /file serves only these (its TEXT_EXTS); /files also
    /// lists attachments such as PDFs and Office files for the desktop.
    static let readableExtensions: Set<String> = [
        "md", "markdown", "txt", "canvas", "csv", "json", "yaml", "yml", "ts", "js", "py", "sh", "css", "html",
    ]

    var isReadable: Bool { Self.readableExtensions.contains(fileExtension) }
    var isMarkdown: Bool { fileExtension == "md" || fileExtension == "markdown" }

    /// Display name for a bare vault path (pins and cached notes carry no
    /// listing row): the basename without its extension.
    static func displayName(for path: String) -> String {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return base }
        return String(base[..<dot])
    }
}

private struct FilesResponse: Decodable {
    let files: [VaultNote]
}

private struct FileResponse: Decodable {
    let path: String
    let text: String
    /// Set when the gateway sent only the head of the file.
    let truncated: Bool?
}

private struct ResolveResponse: Decodable {
    let path: String
}

/// Read-only client for the vault gateway's note routes, authorized by the
/// notes read token. Requests run over the tailnet to the same host as the
/// bridge; an unreachable host drops packets instead of refusing them, so
/// the timeouts are short and the store falls back to its disk cache.
struct NotesClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// GET /files. An empty query lists the most recently modified notes.
    /// `text=1` asks for readable files only, so attachments do not fill
    /// the limit; rows /file cannot serve are dropped here as well.
    func search(_ query: String, limit: Int = 30) async throws -> [VaultNote] {
        let data = try await get("/files", ["q": query, "limit": String(limit), "text": "1"])
        return try JSONDecoder().decode(FilesResponse.self, from: data).files.filter(\.isReadable)
    }

    /// GET /file: the note's raw markdown, at most one character past the
    /// render cap so a long note neither downloads whole nor hits the
    /// gateway's size limit. `truncated` is true when the gateway cut it.
    func read(_ path: String) async throws -> (text: String, truncated: Bool) {
        let data = try await get("/file", ["path": path, "maxChars": String(MarkdownBlocks.characterCap + 1)])
        let file = try JSONDecoder().decode(FileResponse.self, from: data)
        return (file.text, file.truncated ?? false)
    }

    /// GET /note/resolve: a wikilink target to a vault path, resolved by
    /// the gateway with Obsidian's rules. nil when nothing matches.
    func resolve(_ name: String, from: String?) async throws -> String? {
        var params = ["name": name]
        if let from { params["from"] = from }
        do {
            let data = try await get("/note/resolve", params)
            return try JSONDecoder().decode(ResolveResponse.self, from: data).path
        } catch NotesClientError.notFound {
            return nil
        }
    }

    private func get(_ path: String, _ params: [String: String]) async throws -> Data {
        guard let base = BridgeConfig.gatewayURL(path) else { throw NotesClientError.badURL }
        // Encoded by hand: the gateway's URLSearchParams decodes "+" as a
        // space, and vault paths can carry "+", "&" and "#".
        let query = params
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.encode($0.value))" }
            .joined(separator: "&")
        guard let url = URL(string: base.absoluteString + "?" + query) else { throw NotesClientError.badURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(BridgeConfig.notesToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 401, 403:
            // /file answers 403 for a dot path, which a listing never
            // offers, so a 403 here means the token.
            throw NotesClientError.tokenRejected
        case 404: throw NotesClientError.notFound
        default: throw NotesClientError.http(status)
        }
    }

    /// ASCII only: CharacterSet.alphanumerics would pass accented letters
    /// through unencoded, and URL(string:) rejects them.
    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
    )

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
