import AppKit
import SwiftUI

/// One entry in the "/" menu, Notion style.
struct SlashCommand: Identifiable {
    enum Action {
        /// Turns the current line into this block (Notion's "turn into"), replacing its old marker.
        case block(String)
        /// Text around the caret. `ownLine` blocks start a new line when the current one has text.
        case insert(String, String = "", ownLine: Bool = false)
        case date, emoji, page, toc, duplicate, delete
    }

    let title: String
    let hint: String
    let symbol: String
    let keywords: String
    let action: Action
    var id: String { title }

    /// Notion's basic, inline and advanced blocks that have a Markdown form, in Notion's order.
    static let all: [SlashCommand] = [
        .init(title: String(localized: "텍스트"), hint: String(localized: "일반 문단으로"), symbol: "textformat", keywords: "text plain paragraph", action: .block("")),
        .init(title: String(localized: "페이지"), hint: String(localized: "새 문서를 만들어 링크 걸기"), symbol: "doc.badge.plus", keywords: "page subpage new", action: .page),
        .init(title: String(localized: "할 일 목록"), hint: String(localized: "체크박스로 할 일 관리"), symbol: "checklist", keywords: "todo task checkbox", action: .block("- [ ] ")),
        .init(title: String(localized: "제목 1"), hint: String(localized: "큰 섹션 제목"), symbol: "textformat.size.larger", keywords: "# h1 heading title", action: .block("# ")),
        .init(title: String(localized: "제목 2"), hint: String(localized: "중간 섹션 제목"), symbol: "textformat.size", keywords: "## h2 heading", action: .block("## ")),
        .init(title: String(localized: "제목 3"), hint: String(localized: "작은 섹션 제목"), symbol: "textformat.size.smaller", keywords: "### h3 heading", action: .block("### ")),
        .init(title: String(localized: "표"), hint: String(localized: "2×2 표"), symbol: "tablecells", keywords: "table grid",
              action: .insert("| ", " |  |\n| --- | --- |\n|  |  |", ownLine: true)),
        .init(title: String(localized: "글머리 기호 목록"), hint: String(localized: "간단한 목록"), symbol: "list.bullet", keywords: "bullet list ul", action: .block("- ")),
        .init(title: String(localized: "번호 매기기 목록"), hint: String(localized: "순서가 있는 목록"), symbol: "list.number", keywords: "numbered ordered list ol", action: .block("1. ")),
        .init(title: String(localized: "토글"), hint: String(localized: "접고 펼 수 있는 블록"), symbol: "chevron.right.square", keywords: "toggle details collapse",
              action: .insert("<details>\n<summary>", "</summary>\n\n\n\n</details>", ownLine: true)),
        .init(title: String(localized: "인용"), hint: String(localized: "인용문"), symbol: "text.quote", keywords: "quote blockquote", action: .block("> ")),
        // A blank line first, or `---` under a paragraph would make it a heading instead.
        .init(title: String(localized: "구분선"), hint: String(localized: "섹션 나누기"), symbol: "minus", keywords: "divider hr line rule", action: .insert("\n---\n\n", ownLine: true)),
        .init(title: String(localized: "콜아웃"), hint: String(localized: "눈에 띄는 메모"), symbol: "lightbulb", keywords: "callout note tip", action: .block("> 💡 ")),
        // The caret lands after the opening fence: type the language (```python), then Return.
        .init(title: String(localized: "코드"), hint: String(localized: "코드 블록 · 언어 이름부터 입력"), symbol: "chevron.left.forwardslash.chevron.right",
              keywords: "code block snippet", action: .insert("```", "\n```", ownLine: true)),
        .init(title: String(localized: "이미지"), hint: String(localized: "이미지 넣기"), symbol: "photo", keywords: "image picture img", action: .insert("![](", ")")),
        .init(title: String(localized: "링크"), hint: String(localized: "웹 링크·북마크"), symbol: "link", keywords: "link url web book bookmark", action: .insert("[", "](https://)")),
        .init(title: String(localized: "목차"), hint: String(localized: "제목으로 만든 목차"), symbol: "list.bullet.indent", keywords: "toc table of contents outline", action: .toc),
        .init(title: String(localized: "날짜"), hint: String(localized: "오늘 날짜"), symbol: "calendar", keywords: "date today reminder", action: .date),
        .init(title: String(localized: "이모지"), hint: String(localized: "이모지 선택 창"), symbol: "face.smiling", keywords: "emoji", action: .emoji),
        .init(title: String(localized: "각주"), hint: String(localized: "문서 끝에 붙는 메모"), symbol: "number", keywords: "footnote", action: .insert("[^", "]")),
        .init(title: String(localized: "복제"), hint: String(localized: "이 줄을 아래에 복제"), symbol: "plus.square.on.square", keywords: "duplicate dup copy", action: .duplicate),
        .init(title: String(localized: "삭제"), hint: String(localized: "이 줄 지우기"), symbol: "trash", keywords: "delete del remove", action: .delete),
    ]

    /// Spaces are ignored on both sides, so "/제목1", "/할일", "/h1" and "/#" all match.
    func matches(_ query: String) -> Bool {
        query.isEmpty || "\(title)\(keywords)".lowercased().filter { !$0.isWhitespace }.contains(query.lowercased())
    }

    /// /page writes a file next to the document, so an unsaved document can't offer it.
    var needsFolder: Bool {
        if case .page = action { true } else { false }
    }
}

/// Watches the editor for a "/" query and drives the menu panel. The text view keeps keyboard
/// focus throughout; arrow keys, Return/Tab and Esc reach the menu through `handle(_:)`.
@MainActor @Observable
final class SlashMenu {
    private(set) var matches: [SlashCommand] = []
    var selection = 0
    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored var folder: URL?
    @ObservationIgnored private var slash: Int?
    @ObservationIgnored private var dismissedSlash: Int?
    @ObservationIgnored private var panel: SlashPanel?

    func update() {
        guard let textView, let (location, query) = Self.query(in: textView) else {
            dismissedSlash = nil
            return close()
        }
        matches = location == dismissedSlash ? [] : SlashCommand.all.filter { $0.matches(query) && (folder != nil || !$0.needsFolder) }
        guard !matches.isEmpty, let window = textView.window else { return close() }
        selection = slash == location ? min(selection, matches.count - 1) : 0
        slash = location
        let panel = panel ?? SlashPanel(menu: self)
        self.panel = panel
        let anchor = textView.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
        panel.show(below: anchor, rows: matches.count, in: window)
    }

    func handle(_ command: Selector) -> Bool {
        guard slash != nil else { return false }
        switch command {
        case #selector(NSResponder.moveUp(_:)): selection = (selection + matches.count - 1) % matches.count
        case #selector(NSResponder.moveDown(_:)): selection = (selection + 1) % matches.count
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): choose(selection)
        case #selector(NSResponder.cancelOperation(_:)):
            dismissedSlash = slash
            close()
        default: return false
        }
        return true
    }

    /// Every action is one replacement, so a single ⌘Z takes it back.
    func choose(_ index: Int) {
        guard let textView, let slash, matches.indices.contains(index) else { return }
        let action = matches[index].action
        let text = textView.string as NSString
        let query = NSRange(location: slash, length: textView.selectedRange().location - slash)
        let fullLine = text.lineRange(for: query)
        var lineEnd = NSMaxRange(fullLine)
        // Compare UTF-16 units: as Swift strings "\r\n" is a single Character that doesn't "contain" "\n".
        while lineEnd > fullLine.location, [0x0A, 0x0D].contains(text.character(at: lineEnd - 1)) { lineEnd -= 1 }
        let line = NSRange(location: fullLine.location, length: lineEnd - fullLine.location)
        // The line as it reads without the "/query" (and the space typed before it).
        var head = text.substring(with: NSRange(location: line.location, length: slash - line.location))
        while head.last?.isWhitespace == true { head.removeLast() }
        let rest = head + text.substring(with: NSRange(location: NSMaxRange(query), length: lineEnd - NSMaxRange(query)))
        let restIsEmpty = rest.allSatisfy(\.isWhitespace)
        close()

        func replace(_ range: NSRange, with string: String, caret: Int) {
            textView.insertText(string, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + caret, length: 0))
        }
        func place(_ open: String, _ close: String = "", ownLine: Bool) {
            if ownLine, !restIsEmpty {
                replace(line, with: rest + "\n" + open + close, caret: (rest + "\n" + open).utf16.count)
            } else {
                replace(query, with: open + close, caret: open.utf16.count)
            }
        }

        switch action {
        case .block(let marker):
            let parts = rest.wholeMatch(of: Self.blockMarker)
            let turned = String(parts?.1 ?? "") + marker + String(parts?.2 ?? Substring(rest))
            replace(line, with: turned, caret: turned.utf16.count)
        case .insert(let open, let close, let ownLine):
            place(open, close, ownLine: ownLine)
        case .date:
            place(Date.now.formatted(.iso8601.year().month().day()), ownLine: false)
        case .emoji:
            replace(query, with: "", caret: 0)
            NSApp.orderFrontCharacterPalette(textView)
        case .page:
            guard let folder else { return NSSound.beep() }
            // Named first, like any new file; cancelling just drops the "/페이지".
            guard let file = NewFile.create(in: folder, suggesting: .markdown) else { return replace(query, with: "", caret: 0) }
            // <…> keeps a name with spaces readable in the source: [제목 없음](<제목 없음.md>). What a link
            // reads specially is escaped: \ [ ] in the text; \ % # ? < > in the address ("C# 공부.md").
            var title = file.deletingPathExtension().lastPathComponent, address = file.lastPathComponent
            for character in ["\\", "[", "]"] { title = title.replacingOccurrences(of: character, with: "\\" + character) }
            for (raw, escaped) in [("%", "%25"), ("\\", "%5C"), ("#", "%23"), ("?", "%3F"), ("<", "%3C"), (">", "%3E")] {
                address = address.replacingOccurrences(of: raw, with: escaped)
            }
            place("[\(title)](<\(address)>)", ownLine: false)
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, _ in }
        case .toc:
            let headings = markdownHeadings(textView.string)
            guard let top = headings.map(\.level).min() else {
                replace(query, with: "", caret: 0)
                return NSSound.beep()
            }
            let toc = headings.map { heading in
                let title = heading.title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                return String(repeating: "  ", count: heading.level - top) + "- [\(title)](#\(heading.id))"
            }
            place(toc.joined(separator: "\n"), ownLine: true)
        case .duplicate:
            replace(line, with: rest + "\n" + rest, caret: rest.utf16.count)
        case .delete:
            // The last line has no newline of its own, so take the one before it.
            let start = fullLine.location > 0 && NSMaxRange(fullLine) == lineEnd ? fullLine.location - 1 : fullLine.location
            replace(NSRange(location: start, length: NSMaxRange(fullLine) - start), with: "", caret: 0)
        }
    }

    /// Indentation, then an existing block marker (heading, quote or callout, list, to-do), then the text.
    private static let blockMarker =
        /([ \t]*)(?:#{1,6}(?:[ \t]+|$)|>[ \t]?(?:💡[ \t]?)?|(?:[-*+]|\d{1,9}[.)])(?:[ \t]+|$)(?:\[[ xX]\](?:[ \t]+|$))?)?(.*)/

    func close() {
        slash = nil
        panel?.hide()
    }

    /// Breaks the menu ↔ panel cycle when the editor goes away.
    func tearDown() {
        close()
        panel = nil
    }

    /// The "/" being completed: at a line start or after whitespace, with no whitespace typed since.
    private static func query(in textView: NSTextView) -> (Int, String)? {
        let caret = textView.selectedRange()
        guard caret.length == 0 else { return nil }
        let text = textView.string as NSString
        let lineStart = text.lineRange(for: NSRange(location: caret.location, length: 0)).location
        let prefix = text.substring(with: NSRange(location: lineStart, length: caret.location - lineStart))
        guard let slashIndex = prefix.lastIndex(of: "/") else { return nil }
        let before = prefix[..<slashIndex], query = prefix[prefix.index(after: slashIndex)...]
        guard before.last?.isWhitespace ?? true, query.count <= 20, !query.contains(where: \.isWhitespace) else { return nil }
        return (lineStart + before.utf16.count, String(query))
    }
}

/// A child window that never takes key, so typing stays in the editor while the menu is open.
private final class SlashPanel: NSPanel {
    private static let rowHeight: CGFloat = 44

    init(menu: SlashMenu) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentView = FirstMouseHostingView(rootView: SlashMenuView(menu: menu, rowHeight: Self.rowHeight))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(below anchor: NSRect, rows: Int, in window: NSWindow) {
        setContentSize(NSSize(width: 280, height: CGFloat(min(rows, 7)) * Self.rowHeight + 12))
        setFrameTopLeftPoint(NSPoint(x: anchor.minX - 10, y: anchor.minY - 6))
        if parent == nil { window.addChildWindow(self, ordered: .above) }
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// Clicks land on the first try even though the panel is never key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SlashMenuView: View {
    let menu: SlashMenu
    let rowHeight: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(menu.matches.enumerated()), id: \.element.id) { index, command in
                        Button { menu.choose(index) } label: { row(command, selected: index == menu.selection) }
                            .buttonStyle(.plain)
                            .id(index)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .onChange(of: menu.selection) { proxy.scrollTo(menu.selection) }
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private func row(_ command: SlashCommand, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).font(.system(size: 13))
                Text(command.hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: rowHeight)
        .background(selected ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
    }
}
