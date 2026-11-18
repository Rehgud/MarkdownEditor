import AppKit

/// Syntax highlighting for the Markdown source in the preview's Notion palette: content keeps
/// full contrast, syntax markers fade back, headings grow, and each construct gets one color.
/// Styles one display copy of a line at a time; the text storage itself is never restyled.
@MainActor
enum MarkdownHighlighter {
    typealias Attributes = [NSAttributedString.Key: Any]

    static let background = color(0xFFFFFF, 0x191919)
    static let text = color(0x37352F, 0xFFFFFF, darkAlpha: 0.81)
    static let muted = color(0x37352F, 0xFFFFFF, alpha: 0.35, darkAlpha: 0.3)
    private static let quote = color(0x37352F, 0xFFFFFF, alpha: 0.65, darkAlpha: 0.6)
    private static let accent = color(0x337EA9, 0x529CCA)
    private static let code = color(0xEB5757, 0xFF7369)
    private static let codeBackground = color(0x878378, 0x878378, alpha: 0.15, darkAlpha: 0.15)
    private static let codeBlock = color(0x448361, 0x4DAB9A)

    private static let size: CGFloat = 14
    private static let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    private static let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    private static let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)

    static let baseAttributes: Attributes = [
        .font: font,
        .foregroundColor: text,
        .paragraphStyle: { let style = NSMutableParagraphStyle(); style.lineSpacing = 6; return style }(),
    ]

    private struct Rule {
        let regex: NSRegularExpression
        let styles: [(group: Int, attributes: Attributes)]

        init(_ pattern: String, _ styles: [(Int, Attributes)]) {
            regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            self.styles = styles.map { (group: $0.0, attributes: $0.1) }
        }
    }

    /// Applied in order, so later rules win where they overlap (inline code beats emphasis).
    private static let rules: [Rule] = {
        let marker: Attributes = [.foregroundColor: muted]
        let link: Attributes = [.foregroundColor: accent]
        let headings = [22, 18, 16, 14, 14, 14].enumerated().map { level, size in
            Rule("^ {0,3}(#{\(level + 1)})(?:[ \\t]+.*)?$", [
                (0, [.font: NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .bold)]), (1, marker),
            ])
        }
        return headings + [
            Rule("^ {0,3}(>)(.*)$", [(2, [.foregroundColor: quote]), (1, link)]),
            Rule("^[ \\t]*([-*+]|\\d{1,9}[.)])(?=[ \\t])", [(1, [.foregroundColor: accent, .font: bold])]),
            Rule("^[ \\t]*(?:[-*+]|\\d{1,9}[.)])[ \\t]+(\\[[ xX]\\])(?=[ \\t]|$)", [(1, link)]),
            Rule("^ {0,3}(?:(?:-[ \\t]*){3,}|(?:\\*[ \\t]*){3,}|(?:_[ \\t]*){3,})$", [(0, marker)]),
            Rule("^[ \\t]*\\|?(?:[ \\t]*:?-{3,}:?[ \\t]*\\|)+[ \\t]*(?::?-{3,}:?)?[ \\t]*$", [(0, marker)]),
            Rule("\\|", [(0, marker)]),
            Rule("</?[A-Za-z][^>\\n]*>", [(0, marker)]),
            Rule("https?://[^\\s<>()]+", [(0, link)]),
            Rule("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)(\\1)", [(2, [.font: bold]), (1, marker), (3, marker)]),
            // `*` may touch letters (`*강조*가` is emphasis); `_` may not (snake_case isn't).
            Rule("(?<!\\*)(\\*)(?=[^\\s*])(.+?)(?<=[^\\s*])(\\*)(?!\\*)", [(2, [.font: italic]), (1, marker), (3, marker)]),
            Rule("(?<![_\\w])(_)(?=[^\\s_])(.+?)(?<=[^\\s_])(_)(?![_\\w])", [(2, [.font: italic]), (1, marker), (3, marker)]),
            Rule("(~~)(?=\\S)(.+?)(?<=\\S)(~~)", [
                (2, [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: quote]), (1, marker), (3, marker),
            ]),
            Rule("(!?\\[)([^\\]\\n]*)(\\]\\()(<[^>\\n]*>|[^)\\s]*)((?:[ \\t]+\"[^\"\\n]*\")?\\))", [
                (2, link), (1, marker), (3, marker), (4, marker), (5, marker),
            ]),
            Rule("\\[\\^[^\\]\\s]+\\]", [(0, link)]),
            Rule("(`+)(?!`)(.+?)(?<!`)(\\1)(?!`)", [(0, [.foregroundColor: code, .backgroundColor: codeBackground, .font: font])]),
        ]
    }()

    /// Styles one source line (a TextKit 2 paragraph) in place. Code in a fenced block keeps the
    /// plain monospace look: green when its language is unknown, otherwise colored by its tokens.
    static func style(_ line: NSMutableAttributedString, in block: FencedBlock?) {
        let full = NSRange(location: 0, length: line.length)
        line.addAttributes(baseAttributes, range: full)
        if let block {
            let known = block.language.flatMap(CodeLanguage.named) != nil
            return line.addAttribute(.foregroundColor, value: known ? text : codeBlock, range: full)
        }
        let string = line.string
        for rule in rules {
            rule.regex.enumerateMatches(in: string, range: full) { match, _, _ in
                guard let match else { return }
                for style in rule.styles where match.range(at: style.group).location != NSNotFound {
                    line.addAttributes(style.attributes, range: match.range(at: style.group))
                }
            }
        }
    }

    struct FencedBlock {
        /// Fences included.
        let range: NSRange
        /// The code between the fences.
        let content: NSRange
        /// The info string's first word: ```swift.
        let language: String?
    }

    /// ``` and ~~~ fences, including an unclosed one running to the end (as you type it).
    static func fencedCodeBlocks(in text: NSString) -> [FencedBlock] {
        var blocks: [FencedBlock] = []
        var open: (start: Int, contentStart: Int, fence: Character, length: Int, language: String?)?
        var index = 0
        while index < text.length {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(line)
            var first = line.location
            while first < NSMaxRange(line), first - line.location <= 3, text.character(at: first) == 0x20 { first += 1 }
            guard first < NSMaxRange(line), first - line.location <= 3, [0x60, 0x7E].contains(text.character(at: first)) else { continue }
            let content = text.substring(with: line)
            let body = content.drop { $0 == " " }
            guard content.count - body.count <= 3, let fence = body.first, fence == "`" || fence == "~" else { continue }
            let length = body.prefix { $0 == fence }.count
            guard length >= 3 else { continue }
            if let current = open {
                if fence == current.fence, length >= current.length, body.dropFirst(length).allSatisfy(\.isWhitespace) {
                    blocks.append(FencedBlock(range: NSRange(location: current.start, length: NSMaxRange(line) - current.start),
                                              content: NSRange(location: current.contentStart, length: line.location - current.contentStart),
                                              language: current.language))
                    open = nil
                }
            } else if fence == "~" || !body.dropFirst(length).contains("`") {
                // A backtick in the info string makes it inline code (```x```), not a fence.
                let info = body.dropFirst(length).split(whereSeparator: \.isWhitespace).first.map(String.init)
                open = (line.location, NSMaxRange(line), fence, length, info)
            }
        }
        if let current = open {
            blocks.append(FencedBlock(range: NSRange(location: current.start, length: text.length - current.start),
                                      content: NSRange(location: current.contentStart, length: text.length - current.contentStart),
                                      language: current.language))
        }
        return blocks
    }

    static func color(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : alpha)
        }
    }
}

/// Code and plain-text files: VS Code's look, 13pt monospace with 4-space tab stops, and the
/// token colors the preview uses too.
@MainActor
enum CodeTheme {
    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static let attributes: MarkdownHighlighter.Attributes = [
        .font: font,
        .foregroundColor: MarkdownHighlighter.text,
        .paragraphStyle: {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            style.tabStops = []
            style.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
            return style
        }(),
    ]

    private static let colors = Dictionary(uniqueKeysWithValues: TokenKind.allCases.map {
        ($0, MarkdownHighlighter.color($0.colors.light, $0.colors.dark))
    })

    static func color(for kind: TokenKind) -> NSColor { colors[kind]! }
}
