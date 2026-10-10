import Foundation

/// One rendered unit of a note. Inline styling (bold, italic, code, links)
/// is already resolved into the AttributedStrings, so the view only lays
/// blocks out.
struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        /// `checked` is nil for a plain bullet or number, else a task.
        case listItem(marker: String, level: Int, text: AttributedString, checked: Bool?)
        /// A blockquote, or an Obsidian callout when `callout` names its type.
        case quote(callout: String?, title: AttributedString?, lines: [AttributedString])
        case code(language: String?, text: String)
        case rule
        /// Tables, images and embeds the watch does not draw.
        case placeholder(String)
    }

    let id: Int
    let kind: Kind
}

struct ParsedNote {
    let blocks: [MarkdownBlock]
    /// The source ran past `MarkdownBlocks.characterCap` and was cut.
    let truncated: Bool
    /// Unique wikilink targets in reading order, heading and alias stripped.
    let links: [String]
}

/// A small markdown block parser for the watch's note reader. It covers the
/// subset Obsidian notes lean on (headings, lists, tasks, quotes, callouts,
/// fenced code, rules, wikilinks) and turns everything else into plain
/// paragraphs or a one-line placeholder. Pure Foundation, so it also builds
/// in the command-line check under Tests/.
enum MarkdownBlocks {
    /// Rendering cap; longer notes show a "truncated" footer.
    static let characterCap = 40_000
    /// Wikilinks become links with this scheme; the reader resolves them.
    static let wikilinkScheme = "askclaude-note"

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "bmp", "avif", "tif", "tiff"]
    private static let markdownExtensions: Set<String> = ["md", "markdown"]

    /// `sourceCut` marks a source the gateway already cut short.
    static func parse(_ source: String, path: String = "", sourceCut: Bool = false) -> ParsedNote {
        var text = source
        var truncated = sourceCut
        if let cut = text.index(text.startIndex, offsetBy: characterCap, limitedBy: text.endIndex), cut != text.endIndex {
            text = String(text[..<cut])
            truncated = true
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")

        // Non-markdown text files (.json, .py, .canvas) read best verbatim.
        let ext = (path as NSString).pathExtension.lowercased()
        if !ext.isEmpty && !markdownExtensions.contains(ext) {
            let block = MarkdownBlock(id: 0, kind: .code(language: ext, text: text))
            return ParsedNote(blocks: [block], truncated: truncated, links: [])
        }

        var parser = Parser(lines: stripComments(stripFrontmatter(text.components(separatedBy: "\n"))))
        parser.run()
        return ParsedNote(blocks: parser.blocks, truncated: truncated, links: parser.links)
    }

    /// The wikilink target carried by a link this parser produced, or nil
    /// for any other URL.
    static func wikilinkTarget(from url: URL) -> String? {
        guard url.scheme == wikilinkScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let name = items.first(where: { $0.name == "name" })?.value,
              !name.isEmpty else { return nil }
        return name
    }

    static func wikilinkURL(for target: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = target.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(wikilinkScheme)://open?name=\(encoded)")
    }

    /// Drops a leading YAML block fenced by "---" and closed by "---" or
    /// "...". An unclosed fence is left alone rather than eating the note.
    static func stripFrontmatter(_ lines: [String]) -> [String] {
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return lines }
        for i in 1..<max(lines.count, 1) {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                return Array(lines[(i + 1)...])
            }
        }
        return lines
    }

    /// Removes Obsidian comments, `%%` to the next `%%`, which can open and
    /// close anywhere in a line and span several. Fenced code and inline code
    /// spans keep their `%%`. A line left empty becomes a blank line, and the
    /// whitespace after a closer at the start of a line is dropped.
    static func stripComments(_ lines: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var inComment = false
        var fence: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inComment, let open = fence {
                out.append(line)
                if trimmed.hasPrefix(open) && trimmed.drop(while: { $0 == open.first }).allSatisfy(\.isWhitespace) { fence = nil }
                continue
            }
            if !inComment, let open = Parser.fence(trimmed) {
                out.append(line)
                fence = open
                continue
            }
            guard inComment || line.contains("%%") else {
                out.append(line)
                continue
            }
            let chars = Array(line)
            var kept = ""
            var removed = false
            var i = 0
            while i < chars.count {
                if chars[i] == "%", i + 1 < chars.count, chars[i + 1] == "%" {
                    inComment.toggle()
                    removed = true
                    i += 2
                    if !inComment && kept.allSatisfy({ $0 == " " || $0 == "\t" }) {
                        while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
                    }
                    continue
                }
                if inComment {
                    i += 1
                    continue
                }
                if chars[i] == "\\", i + 1 < chars.count {
                    kept.append(chars[i])
                    kept.append(chars[i + 1])
                    i += 2
                    continue
                }
                if chars[i] == "`" {
                    // A code span copies through whole; an unmatched run is text.
                    let run = chars[i...].prefix(while: { $0 == "`" }).count
                    var j = i + run
                    var close: Int?
                    while j < chars.count {
                        guard chars[j] == "`" else { j += 1; continue }
                        let other = chars[j...].prefix(while: { $0 == "`" }).count
                        if other == run { close = j; break }
                        j += other
                    }
                    let end = close.map { $0 + run } ?? (i + run)
                    kept += String(chars[i..<end])
                    i = end
                    continue
                }
                kept.append(chars[i])
                i += 1
            }
            out.append(removed && kept.trimmingCharacters(in: .whitespaces).isEmpty ? "" : kept)
        }
        return out
    }

    static func isImage(_ target: String) -> Bool {
        let file = target.split(separator: "|").first.map(String.init) ?? target
        return imageExtensions.contains((file as NSString).pathExtension.lowercased())
    }

    // MARK: Inline

    private static let embedWikiRegex = try! NSRegularExpression(pattern: #"!\[\[([^\[\]\n]+?)\]\]"#)
    private static let embedImageRegex = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let wikilinkRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n]+?)\]\]"#)

    private static let inlineOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    /// Inline markdown to an AttributedString. Embeds collapse to a
    /// bracketed placeholder and wikilinks become `askclaude-note:` links
    /// before Foundation's inline-only parser runs. Code spans keep their
    /// brackets literal, as Obsidian shows them.
    static func inline(_ raw: String, links: inout [String]) -> AttributedString {
        let s = outsideCodeSpans(raw) { segment in
            var s = replace(embedWikiRegex, in: segment) { groups in
                isImage(groups[1]) ? "\\[Image\\]" : "\\[Embed: \(escape(displayName(groups[1])))\\]"
            }
            s = replace(embedImageRegex, in: s) { _ in "\\[Image\\]" }
            return replace(wikilinkRegex, in: s) { groups in
                let (target, display) = splitWikilink(groups[1])
                guard !target.isEmpty, let url = wikilinkURL(for: target) else {
                    // A same-note heading link ([[#Heading]]) has nowhere to go.
                    return escape(display)
                }
                if !links.contains(target) { links.append(target) }
                return "[\(escape(display))](\(url.absoluteString))"
            }
        }
        if let parsed = try? AttributedString(markdown: s, options: inlineOptions) {
            return parsed
        }
        return AttributedString(raw)
    }

    /// Splits "Note#Heading|Alias" into the note part (what /note/resolve
    /// needs) and the text Obsidian would show.
    static func splitWikilink(_ inner: String) -> (target: String, display: String) {
        var body = inner
        var alias: String?
        if let bar = body.firstIndex(of: "|") {
            alias = String(body[body.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<bar])
        }
        // Wikilinks inside tables escape their bar as "\|".
        if body.hasSuffix("\\") { body.removeLast() }
        body = body.trimmingCharacters(in: .whitespaces)
        let target: String
        let heading: String?
        if let hash = body.firstIndex(of: "#") {
            target = String(body[..<hash]).trimmingCharacters(in: .whitespaces)
            heading = String(body[body.index(after: hash)...]).replacingOccurrences(of: "#", with: " > ")
        } else {
            target = body
            heading = nil
        }
        if let alias, !alias.isEmpty { return (target, alias) }
        if let heading {
            return (target, target.isEmpty ? heading : "\(target) > \(heading)")
        }
        return (target, target)
    }

    private static func displayName(_ target: String) -> String {
        splitWikilink(target).display
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            if "\\`*_[]<>~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Runs `transform` over the text outside inline code spans and copies
    /// each span through untouched. As in CommonMark, a backtick run opens a
    /// span closed by the next run of the same length; an unmatched run and
    /// a backslash-escaped backtick stay plain text. Escaped "\\[" and "\\!"
    /// are hidden from `transform` and restored after it.
    private static func outsideCodeSpans(_ text: String, _ transform: (String) -> String) -> String {
        let chars = Array(text)
        var out = ""
        var plain = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\", i + 1 < chars.count {
                // An escaped "[" or "!" goes in as a placeholder so the
                // wikilink and embed patterns cannot start on it.
                switch chars[i + 1] {
                case "[": plain.append(escapedBracket)
                case "!": plain.append(escapedBang)
                default:
                    plain.append(ch)
                    plain.append(chars[i + 1])
                }
                i += 2
                continue
            }
            guard ch == "`" else {
                plain.append(ch)
                i += 1
                continue
            }
            let run = chars[i...].prefix(while: { $0 == "`" }).count
            var j = i + run
            var close: Int?
            while j < chars.count {
                guard chars[j] == "`" else { j += 1; continue }
                let other = chars[j...].prefix(while: { $0 == "`" }).count
                if other == run { close = j; break }
                j += other
            }
            if let close {
                out += restore(transform(plain))
                plain = ""
                out += String(chars[i..<(close + run)])
                i = close + run
            } else {
                plain += String(repeating: "`", count: run)
                i += run
            }
        }
        return out + restore(transform(plain))
    }

    private static let escapedBracket: Character = "\u{E000}"
    private static let escapedBang: Character = "\u{E001}"

    private static func restore(_ text: String) -> String {
        guard text.contains(escapedBracket) || text.contains(escapedBang) else { return text }
        return text
            .replacingOccurrences(of: String(escapedBracket), with: "\\[")
            .replacingOccurrences(of: String(escapedBang), with: "\\!")
    }

    /// Regex replace with a closure over the capture groups (group 0 is the
    /// whole match).
    private static func replace(_ regex: NSRegularExpression, in text: String, _ transform: ([String]) -> String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += transform(groups)
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}

// MARK: Block parser

private struct Parser {
    let lines: [String]
    var blocks: [MarkdownBlock] = []
    var links: [String] = []

    private var paragraph: [String] = []
    /// The list item still collecting continuation lines.
    private var item: (marker: String, level: Int, raw: String, checked: Bool?)?
    /// Indent widths of the open list levels, outermost first.
    private var listIndents: [Int] = []
    private var lastWasBlank = false

    init(lines: [String]) {
        self.lines = lines
    }

    mutating func run() {
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = Self.indentWidth(line)
            defer { lastWasBlank = trimmed.isEmpty }

            if trimmed.isEmpty {
                flushParagraph()
                flushItem()
                i += 1
                continue
            }

            if let fence = Self.fence(trimmed) {
                flushAll()
                listIndents.removeAll()
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence) && t.drop(while: { $0 == fence.first }).allSatisfy(\.isWhitespace) { break }
                    body.append(Self.dropIndent(lines[i], upTo: indent))
                    i += 1
                }
                i += 1
                append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }

            if indent < 4, let heading = Self.atxHeading(trimmed) {
                flushAll()
                listIndents.removeAll()
                append(.heading(level: heading.level, text: inline(heading.title)))
                i += 1
                continue
            }

            // Setext heading: a "===" or "---" underline on a paragraph.
            if !paragraph.isEmpty && item == nil && (Self.isRun(trimmed, of: "=") || Self.isRun(trimmed, of: "-")) {
                let title = paragraph.joined(separator: "\n")
                paragraph.removeAll()
                append(.heading(level: trimmed.hasPrefix("=") ? 1 : 2, text: inline(title)))
                i += 1
                continue
            }

            if Self.isRule(trimmed) {
                flushAll()
                listIndents.removeAll()
                append(.rule)
                i += 1
                continue
            }

            // GFM table: a header row and a delimiter row with the same cell
            // count. A list item is never a header.
            if i + 1 < lines.count, let columns = Self.tableSeparatorCells(lines[i + 1]),
               Self.tableHeaderCells(trimmed) == columns, Self.listItem(trimmed) == nil {
                flushAll()
                listIndents.removeAll()
                var j = i + 2
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") || t.hasPrefix(">") || Self.listItem(t) != nil { break }
                    j += 1
                }
                let rows = j - i - 2
                append(.placeholder("Table (\(rows) \(rows == 1 ? "row" : "rows"))"))
                i = j
                continue
            }

            if trimmed.hasPrefix(">") {
                flushAll()
                listIndents.removeAll()
                var body: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    body.append(Self.stripQuoteMarkers(t))
                    i += 1
                }
                appendQuote(body)
                continue
            }

            if Self.isStandaloneEmbed(trimmed) {
                flushAll()
                append(.placeholder(Self.embedLabel(trimmed)))
                i += 1
                continue
            }

            if let parsed = Self.listItem(trimmed) {
                flushParagraph()
                flushItem()
                let level = listLevel(for: indent)
                item = (parsed.marker, level, parsed.text, parsed.checked)
                i += 1
                continue
            }

            // Continuation of the open list item (indented or lazy).
            if item != nil && !lastWasBlank {
                item?.raw += "\n" + trimmed
                i += 1
                continue
            }

            flushItem()
            if paragraph.isEmpty { listIndents.removeAll() }
            paragraph.append(trimmed)
            i += 1
        }
        flushAll()
    }

    // MARK: Emitting

    private mutating func append(_ kind: MarkdownBlock.Kind) {
        blocks.append(MarkdownBlock(id: blocks.count, kind: kind))
    }

    private mutating func inline(_ raw: String) -> AttributedString {
        MarkdownBlocks.inline(raw, links: &links)
    }

    private mutating func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        let raw = paragraph.joined(separator: "\n")
        paragraph.removeAll()
        append(.paragraph(inline(raw)))
    }

    private mutating func flushItem() {
        guard let open = item else { return }
        item = nil
        append(.listItem(marker: open.marker, level: open.level, text: inline(open.raw), checked: open.checked))
    }

    private mutating func flushAll() {
        flushParagraph()
        flushItem()
    }

    private mutating func listLevel(for width: Int) -> Int {
        while let last = listIndents.last, width < last { listIndents.removeLast() }
        if listIndents.last.map({ width > $0 }) ?? true { listIndents.append(width) }
        return min(listIndents.count - 1, 5)
    }

    /// Quote lines (markers already stripped) to a quote block. A first line
    /// of "[!type] Title" makes it an Obsidian callout. List lines keep their
    /// own entry; other lines join into paragraphs split on blanks.
    private mutating func appendQuote(_ body: [String]) {
        var lines = body
        var callout: String?
        var title: AttributedString?
        if let first = lines.first, let parsed = Self.calloutHeader(first) {
            callout = parsed.type
            title = inline(parsed.title)
            lines.removeFirst()
        }
        var entries: [AttributedString] = []
        var pending: [String] = []
        func flushPending(_ parser: inout Parser) {
            guard !pending.isEmpty else { return }
            entries.append(parser.inline(pending.joined(separator: "\n")))
            pending.removeAll()
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                flushPending(&self)
            } else if let parsed = Self.listItem(t) {
                flushPending(&self)
                entries.append(inline("\(parsed.marker) \(parsed.text)"))
            } else {
                pending.append(t)
            }
        }
        flushPending(&self)
        append(.quote(callout: callout, title: title, lines: entries))
    }

    // MARK: Line classifiers

    static func indentWidth(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 } else if ch == "\t" { width += 4 } else { break }
        }
        return width
    }

    static func dropIndent(_ line: String, upTo width: Int) -> String {
        var dropped = 0
        var index = line.startIndex
        while index < line.endIndex, dropped < width {
            let ch = line[index]
            if ch == " " { dropped += 1 } else if ch == "\t" { dropped += 4 } else { break }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    /// The opening fence run ("```" or "~~~", three or more) or nil.
    static func fence(_ trimmed: String) -> String? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        // A backtick fence's info string cannot itself hold a backtick.
        if first == "`" && trimmed.dropFirst(run.count).contains("`") { return nil }
        return String(run)
    }

    static func atxHeading(_ trimmed: String) -> (level: Int, title: String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes: "## Title ##".
        if let range = title.range(of: #"\s+#+$"#, options: .regularExpression) {
            title.removeSubrange(range)
        } else if title.allSatisfy({ $0 == "#" }) {
            title = ""
        }
        return (hashes, title)
    }

    static func isRun(_ trimmed: String, of char: Character) -> Bool {
        !trimmed.isEmpty && trimmed.allSatisfy { $0 == char }
    }

    static func isRule(_ trimmed: String) -> Bool {
        for char in ["-", "*", "_"] as [Character] {
            let compact = trimmed.filter { $0 != " " && $0 != "\t" }
            if compact.count >= 3 && compact.allSatisfy({ $0 == char }) { return true }
        }
        return false
    }

    /// The column count of a delimiter row ("|---|:-:|"), or nil. It needs
    /// at least one "|", so a bare "---" or "-" stays a rule or underline.
    static func tableSeparatorCells(_ line: String) -> Int? {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return nil }
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        let cells = t.split(separator: "|", omittingEmptySubsequences: false)
        guard !cells.isEmpty else { return nil }
        let valid = cells.allSatisfy { cell in
            var c = cell.trimmingCharacters(in: .whitespaces)
            if c.hasPrefix(":") { c.removeFirst() }
            if c.hasSuffix(":") { c.removeLast() }
            return !c.isEmpty && c.allSatisfy { $0 == "-" }
        }
        return valid ? cells.count : nil
    }

    /// The cell count of a header row, or nil when it holds no cell bar.
    /// Escaped "\\|" and bars inside wikilinks or code spans do not split.
    static func tableHeaderCells(_ trimmed: String) -> Int? {
        let chars = Array(trimmed)
        var bars: [Int] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\" {
                i += 2
            } else if ch == "[", i + 1 < chars.count, chars[i + 1] == "[" {
                var j = i + 2
                while j + 1 < chars.count && !(chars[j] == "]" && chars[j + 1] == "]") { j += 1 }
                i = j + 1 < chars.count ? j + 2 : i + 2
            } else if ch == "`" {
                let run = chars[i...].prefix(while: { $0 == "`" }).count
                var j = i + run
                var close: Int?
                while j < chars.count {
                    guard chars[j] == "`" else { j += 1; continue }
                    let other = chars[j...].prefix(while: { $0 == "`" }).count
                    if other == run { close = j; break }
                    j += other
                }
                i = close.map { $0 + run } ?? (i + run)
            } else {
                if ch == "|" { bars.append(i) }
                i += 1
            }
        }
        guard let first = bars.first, let last = bars.last else { return nil }
        var cells = bars.count + 1
        if first == 0 { cells -= 1 }
        if last == chars.count - 1 && last != 0 { cells -= 1 }
        return cells >= 1 ? cells : nil
    }

    static func stripQuoteMarkers(_ trimmed: String) -> String {
        var t = Substring(trimmed)
        while t.first == ">" {
            t = t.dropFirst()
            if t.first == " " { t = t.dropFirst() }
        }
        return String(t)
    }

    static func calloutHeader(_ line: String) -> (type: String, title: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[!"), let close = t.firstIndex(of: "]") else { return nil }
        let type = t[t.index(t.startIndex, offsetBy: 2)..<close].lowercased()
        guard !type.isEmpty, type.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        var rest = t[t.index(after: close)...]
        if rest.first == "+" || rest.first == "-" { rest = rest.dropFirst() }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return (type, title.isEmpty ? type.prefix(1).uppercased() + type.dropFirst() : title)
    }

    static func isStandaloneEmbed(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("![") else { return false }
        if trimmed.hasPrefix("![["), trimmed.hasSuffix("]]") {
            return !trimmed.dropFirst(3).dropLast(2).contains("]]")
        }
        return trimmed.hasSuffix(")") && trimmed.contains("](") && trimmed.filter({ $0 == "(" }).count == 1
    }

    static func embedLabel(_ trimmed: String) -> String {
        guard trimmed.hasPrefix("![[") else { return "Image" }
        let inner = String(trimmed.dropFirst(3).dropLast(2))
        if MarkdownBlocks.isImage(inner) { return "Image" }
        return "Embed: \(MarkdownBlocks.splitWikilink(inner).display)"
    }

    /// "- text", "* text", "+ text", "12. text" or "3) text", with an
    /// optional task box. Returns the marker to draw and the item text.
    static func listItem(_ trimmed: String) -> (marker: String, text: String, checked: Bool?)? {
        var marker: String
        var rest: Substring
        if let first = trimmed.first, "-*+".contains(first) {
            rest = trimmed.dropFirst()
            marker = "•"
        } else {
            let digits = trimmed.prefix(while: \.isNumber)
            guard (1...9).contains(digits.count) else { return nil }
            rest = trimmed.dropFirst(digits.count)
            guard let delim = rest.first, delim == "." || delim == ")" else { return nil }
            rest = rest.dropFirst()
            marker = "\(digits)."
        }
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        var checked: Bool?
        if rest.count >= 3, rest.first == "[", rest[rest.index(rest.startIndex, offsetBy: 2)] == "]" {
            let after = rest.dropFirst(3)
            if after.isEmpty || after.first == " " {
                let box = rest[rest.index(after: rest.startIndex)]
                checked = box != " "
                marker = checked == true ? "☑" : "☐"
                rest = after.drop(while: { $0 == " " })
            }
        }
        return (marker, String(rest), checked)
    }
}
