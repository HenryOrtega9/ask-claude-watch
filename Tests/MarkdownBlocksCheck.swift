import Foundation

/// Command-line check for the note reader's markdown parser. Not part of
/// the Xcode project; run from the repo root:
///
///     swiftc -parse-as-library -o /tmp/md-check Sources/MarkdownBlocks.swift Tests/MarkdownBlocksCheck.swift && /tmp/md-check
@main
struct MarkdownBlocksCheck {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("ok   \(label)")
        } else {
            failures += 1
            print("FAIL \(label)")
        }
    }

    static func plain(_ text: AttributedString) -> String {
        String(text.characters)
    }

    static func main() {
        let note = """
        ---
        type: note
        tags: [a, b]
        ---
        # Title ##
        Intro with **bold**, *italic*, `code` and [[Other Note#Part|alias]].
        Second line joins [[Plain]] and [[Folder/Deep#Sec]].

        - one
          - nested [[Plain]]
        	- tab nested
        - [ ] open task
        - [x] done task
        3. third

        > [!warning]- Careful
        > body line
        > - quoted item

        > plain quote

        ```swift
        let x = 1
        # not a heading
        ```

        | a | b |
        |---|:-:|
        | 1 | 2 |
        | 3 | 4 |

        ![[photo.png]]
        ![[Some Note]]
        ![alt](pic.jpg)
        ***
        Setext
        ===
        %% hidden comment %%
        [[#Local heading]] stays text.
        """
        let parsed = MarkdownBlocks.parse(note, path: "Folder/Note.md")
        for block in parsed.blocks { print("  ", block.id, describe(block.kind)) }

        var kinds = parsed.blocks.map { describe($0.kind) }
        expect(kinds.first == "h1 Title", "frontmatter stripped, closing hashes dropped")
        expect(kinds.contains { $0.hasPrefix("p Intro with bold, italic, code and alias.\nSecond line joins Plain and Folder/Deep > Sec.") }, "inline styling, wikilink display")
        expect(kinds.contains("li0 • one"), "top-level bullet")
        expect(kinds.contains("li1 • nested Plain"), "space-nested bullet")
        expect(kinds.contains("li2 • tab nested"), "tab indent deeper than two spaces nests further")
        expect(kinds.contains("li0 ☐ open task (task false)"), "open task")
        expect(kinds.contains("li0 ☑ done task (task true)"), "done task")
        expect(kinds.contains("li0 3. third"), "numbered item")
        expect(kinds.contains("quote[warning] Careful | body line / • quoted item"), "callout with fold marker")
        expect(kinds.contains("quote[-] | plain quote"), "plain blockquote")
        expect(kinds.contains("code(swift) let x = 1\n# not a heading"), "fenced code verbatim")
        expect(kinds.contains("placeholder Table (2 rows)"), "table placeholder")
        expect(kinds.filter { $0 == "placeholder Image" }.count == 2, "image embeds")
        expect(kinds.contains("placeholder Embed: Some Note"), "note embed")
        expect(kinds.contains("rule"), "horizontal rule")
        expect(kinds.contains("h1 Setext"), "setext heading")
        expect(!kinds.contains { $0.contains("hidden comment") }, "obsidian comment dropped")
        expect(kinds.contains("p Local heading stays text."), "same-note heading link is plain text")
        expect(parsed.links == ["Other Note", "Plain", "Folder/Deep"], "unique link targets in order: \(parsed.links)")
        expect(!parsed.truncated, "short note not truncated")

        // The wikilink becomes a link the reader can decode back.
        var linkTargets: [String] = []
        for block in parsed.blocks {
            if case .paragraph(let text) = block.kind {
                for run in text.runs { if let url = run.link, let t = MarkdownBlocks.wikilinkTarget(from: url) { linkTargets.append(t) } }
            }
        }
        expect(linkTargets.prefix(3) == ["Other Note", "Plain", "Folder/Deep"], "wikilink URLs round-trip: \(linkTargets)")

        let special = MarkdownBlocks.parse("See [[A & B+C (draft)|the *draft*]].", path: "x.md")
        if case .paragraph(let text) = special.blocks.first?.kind {
            let url = text.runs.compactMap(\.link).first
            expect(url.flatMap(MarkdownBlocks.wikilinkTarget) == "A & B+C (draft)", "special characters survive encoding")
            expect(plain(text) == "See the *draft*.", "alias text escaped literally: \(plain(text))")
        } else {
            expect(false, "special wikilink paragraph")
        }

        // Brackets inside a code span stay literal and are not links.
        let spans = MarkdownBlocks.parse("Use `[[Note|Alias]]` syntax and `![[img.png]]` too, ``a `[[X]]` b`` and [[Real]], \\`[[Esc]]\\`.", path: "c.md")
        kinds = spans.blocks.map { describe($0.kind) }
        expect(kinds == ["p Use [[Note|Alias]] syntax and ![[img.png]] too, a `[[X]]` b and Real, `Esc`."], "wikilinks inside code spans stay literal: \(kinds)")
        expect(spans.links == ["Real", "Esc"], "code-span wikilinks not listed, escaped backticks are not a span: \(spans.links)")
        let unmatched = MarkdownBlocks.parse("Stray ` tick then [[Linked]].", path: "c.md")
        expect(unmatched.links == ["Linked"], "unmatched backtick does not hide a wikilink: \(unmatched.links)")

        // A closed comment followed by text keeps the text; a multi-line
        // comment keeps what follows its closing marker.
        let comments = MarkdownBlocks.parse("%% hidden %% Visible text\nnext line\n\nafter\n%%\nsecret\nstill %% tail\n\nend", path: "m.md")
        kinds = comments.blocks.map { describe($0.kind) }
        expect(kinds == ["p Visible text\nnext line", "p after", "p tail", "p end"], "inline comment then text: \(kinds)")

        // A comment opened mid-line hides through its closer on a later line.
        let midComment = MarkdownBlocks.parse("Text %% start\nhidden\n%%\nVisible one\n\nVisible two", path: "m.md")
        kinds = midComment.blocks.map { describe($0.kind) }
        expect(kinds == ["p Text", "p Visible one", "p Visible two"], "mid-line comment opener: \(kinds)")
        let codeComment = MarkdownBlocks.parse("Use `%%` here\n```\n%% kept\n```\nafter", path: "m.md")
        kinds = codeComment.blocks.map { describe($0.kind) }
        expect(kinds == ["p Use %% here", "code() %% kept", "p after"], "%% in code is not a comment: \(kinds)")

        // An escaped bracket is literal text, not a wikilink.
        let escaped = MarkdownBlocks.parse("Use \\[[Note]] syntax", path: "e.md")
        kinds = escaped.blocks.map { describe($0.kind) }
        expect(kinds == ["p Use [[Note]] syntax"] && escaped.links.isEmpty, "escaped wikilink stays literal: \(kinds) \(escaped.links)")
        let escapedEmbed = MarkdownBlocks.parse("\\![[pic.png]] and \\\\[[Real]]", path: "e.md")
        expect(!describe(escapedEmbed.blocks[0].kind).contains("Image") && escapedEmbed.links == ["pic.png", "Real"], "escaped bang is not an embed: \(escapedEmbed.blocks.map { describe($0.kind) }) \(escapedEmbed.links)")

        // A divider under a line holding a pipe is not a table delimiter.
        let aliasRule = MarkdownBlocks.parse("See [[Project|the project]] for details\n---\nNext para", path: "t.md")
        kinds = aliasRule.blocks.map { describe($0.kind) }
        expect(!kinds.contains { $0.hasPrefix("placeholder Table") } && kinds.last == "p Next para", "wikilink alias bar is not a table: \(kinds)")
        let bulletRule = MarkdownBlocks.parse("- **Sep 22 | CLAUDE** text [[X]]\n---\n- next | with pipe\nafter", path: "t.md")
        kinds = bulletRule.blocks.map { describe($0.kind) }
        expect(kinds == ["li0 • Sep 22 | CLAUDE text X", "rule", "li0 • next | with pipe\nafter"], "bullet above a rule is not a table: \(kinds)")
        let bareDash = MarkdownBlocks.parse("a | b\n-\nc", path: "t.md")
        kinds = bareDash.blocks.map { describe($0.kind) }
        expect(!kinds.contains { $0.hasPrefix("placeholder Table") }, "bare dash is not a delimiter: \(kinds)")
        let mismatch = MarkdownBlocks.parse("a | b | c\n|---|---|\nrow | x", path: "t.md")
        kinds = mismatch.blocks.map { describe($0.kind) }
        expect(!kinds.contains { $0.hasPrefix("placeholder Table") }, "header and delimiter cell counts must match: \(kinds)")
        let tableThenList = MarkdownBlocks.parse("| a | b |\n|---|:-:|\n| 1 | 2 |\n- item | pipe", path: "t.md")
        kinds = tableThenList.blocks.map { describe($0.kind) }
        expect(kinds == ["placeholder Table (1 row)", "li0 • item | pipe"], "a list item ends the table: \(kinds)")
        let aliasTable = MarkdownBlocks.parse("| [[A\\|b]] | `x|y` |\n|---|---|\n| 1 | 2 |", path: "t.md")
        expect(aliasTable.blocks.map { describe($0.kind) } == ["placeholder Table (1 row)"], "bars in wikilinks and code do not split header cells")

        let long = String(repeating: "word ", count: 10_000)
        let cut = MarkdownBlocks.parse(long, path: "long.md")
        expect(cut.truncated, "long note truncated")
        // The paragraph's trailing space is trimmed, so one under the cap.
        expect(plain(paragraphText(cut)).count == MarkdownBlocks.characterCap - 1, "cap is exact")

        let tabs = MarkdownBlocks.parse("- a\n\t- b\n\t\t- c\n\t- d\n- e", path: "t.md")
        expect(tabs.blocks.map { describe($0.kind) } == ["li0 • a", "li1 • b", "li2 • c", "li1 • d", "li0 • e"], "tab-indented levels")

        let json = MarkdownBlocks.parse("{\"a\": 1}", path: "data.json")
        kinds = json.blocks.map { describe($0.kind) }
        expect(kinds == ["code(json) {\"a\": 1}"], "non-markdown file renders verbatim")

        let unclosed = MarkdownBlocks.parse("---\nnot frontmatter\n\nbody", path: "u.md")
        expect(unclosed.blocks.count >= 2, "unclosed frontmatter left alone")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func paragraphText(_ note: ParsedNote) -> AttributedString {
        if case .paragraph(let text) = note.blocks.first?.kind { return text }
        return AttributedString()
    }

    static func describe(_ kind: MarkdownBlock.Kind) -> String {
        switch kind {
        case .heading(let level, let text): return "h\(level) \(plain(text))"
        case .paragraph(let text): return "p \(plain(text))"
        case .listItem(let marker, let level, let text, let checked):
            return "li\(level) \(marker) \(plain(text))" + (checked.map { " (task \($0))" } ?? "")
        case .quote(let callout, let title, let lines):
            return "quote[\(callout ?? "-")] " + (title.map { plain($0) + " " } ?? "") + "| " + lines.map(plain).joined(separator: " / ")
        case .code(let language, let text): return "code(\(language ?? "")) \(text)"
        case .rule: return "rule"
        case .placeholder(let label): return "placeholder \(label)"
        }
    }
}
