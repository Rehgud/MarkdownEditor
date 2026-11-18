import Foundation

/// What a token is. The editor and the preview color each kind the same way, from VS Code's
/// Light+ and Dark+ themes.
enum TokenKind: CaseIterable, Sendable {
    case keyword, string, comment, number, type, function, constant, property, tag, attribute

    /// sRGB hex for the light and dark appearance.
    var colors: (light: UInt32, dark: UInt32) {
        switch self {
        case .keyword, .constant: (0x0000FF, 0x569CD6)
        case .string: (0xA31515, 0xCE9178)
        case .comment: (0x008000, 0x6A9955)
        case .number: (0x098658, 0xB5CEA8)
        case .type: (0x267F99, 0x4EC9B0)
        case .function: (0x795E26, 0xDCDCAA)
        case .property: (0x001080, 0x9CDCFE)
        case .tag: (0x800000, 0x569CD6)
        case .attribute: (0xE50000, 0x9CDCFE)
        }
    }

    var cssClass: String { "tk-\(self)" }

    /// One rule per kind for the preview, light and dark.
    static let css: String = {
        func rules(dark: Bool) -> String {
            allCases.map { kind in
                let hex = dark ? kind.colors.dark : kind.colors.light
                return ".\(kind.cssClass) { color: #\(String(hex, radix: 16, uppercase: true).leftPadded(to: 6)); }"
            }.joined(separator: "\n")
        }
        return rules(dark: false) + "\n@media (prefers-color-scheme: dark) {\n" + rules(dark: true) + "\n}\n"
    }()
}

struct SyntaxToken: Sendable {
    let range: NSRange
    let kind: TokenKind
}

/// How one language looks to the tokenizer: a table entry, not a parser. Keywords, comment and
/// string delimiters, and a few switches for the shapes that differ between languages.
struct CodeLanguage: Sendable {
    var keywords: Set<String> = []
    var constants: Set<String> = []
    var builtinTypes: Set<String> = []
    var lineComments: [String] = []
    /// Shell, YAML and SCSS: a comment starts a line or follows a space, so `$#`, `a#b` and
    /// `http://` aren't comments.
    var commentsAfterSpace = false
    var blockComment: (open: String, close: String)? = nil
    /// Longest first where delimiters share a prefix (`"""` before `"`).
    var strings = ["\"", "'"]
    var multilineStrings: Set<String> = []
    /// Delimiters whose backslashes are literal: shell `'…'`, Go's `` `…` ``.
    var rawStrings: Set<String> = []
    /// What opens Rust's `r#"…"#` (lower case) and C++'s `R"x(…)x"` (upper case).
    var rawStringPrefixes: Set<String> = []
    /// Here-documents run to a line that is the word they name: shell `<< WORD`, Ruby `<<~WORD`,
    /// PHP `<<<WORD`.
    var heredoc: Heredoc? = nil
    enum Heredoc { case shell, ruby, php }
    /// Shell: `\'` outside a string is a plain character, and `$'…'` has escapes.
    var backslashEscapes = false
    /// YAML's `key: |` and `key: >`: the deeper-indented lines below are text.
    var blockScalars = false
    /// Rust: `'a'` is a character, a lone `'a` a lifetime.
    var charLiterals = false
    var caseInsensitive = false
    var capitalizedTypes = true
    /// JSON and YAML: a string followed by `:` is a key.
    var keyedStrings = false
    /// YAML `key:`, CSS `property:`, TOML `key =`: the first word on a line, before this, is a key.
    var keySeparator: UInt16? = nil
    var hyphenatedWords = false
    var dollarVariables = false
    /// Decorators and annotations (`@MainActor`), CSS at-rules (`@media`), Ruby's `@ivar`.
    var atWords: TokenKind? = nil
    /// C's `#include`, Swift's `#if`.
    var hashDirectives = false
    /// Rust's `println!`.
    var bangMacros = false
    var markup = false
    /// Python and YAML open a block after `:`.
    var indentsAfterColon = false
}

extension CodeLanguage {
    /// A language by file-format id or Markdown fence name (`js`, `py`, `sh`, …).
    static func named(_ name: String) -> CodeLanguage? {
        switch name.lowercased() {
        case "swift": swift
        case "python", "py", "pyw", "python3": python
        case "javascript", "js", "jsx", "mjs", "cjs", "node": javascript
        case "typescript", "ts", "tsx", "mts", "cts": typescript
        case "java": java
        case "kotlin", "kt", "kts": kotlin
        case "go", "golang": go
        case "rust", "rs": rust
        case "c", "h", "objc", "objective-c", "m": c
        case "cpp", "c++", "cc", "cxx", "hpp", "hh", "mm": cpp
        case "shell", "sh", "bash", "zsh", "console", "shellscript": shell
        case "ruby", "rb": ruby
        case "php": php
        case "sql", "mysql", "postgresql", "postgres", "sqlite": sql
        case "json", "jsonc", "json5": json
        case "yaml", "yml": yaml
        case "toml", "ini", "cfg": toml
        case "css": css
        case "scss", "less", "sass": scss
        case "html", "htm", "xhtml", "xml", "svg", "vue", "plist": markupLanguage
        default: nil
        }
    }

    private static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }

    private static let jsKeywords = """
        break case catch class const continue debugger default delete do else export extends finally for function \
        if import in instanceof let new of return super switch this throw try typeof var void while with yield \
        async await static get set from as
        """

    static let swift = CodeLanguage(
        keywords: words("""
            associatedtype class deinit enum extension fileprivate func import init inout internal let open operator \
            private precedencegroup protocol public rethrows static struct subscript typealias var break case catch \
            continue default defer do else fallthrough for guard if in repeat return throw switch where while as is \
            try await async throws some any self Self super actor nonisolated isolated final lazy mutating override \
            required weak unowned convenience dynamic indirect get set willSet didSet macro package consume borrowing consuming
            """),
        constants: words("true false nil"),
        lineComments: ["//"], blockComment: ("/*", "*/"),
        strings: ["\"\"\"", "\""], multilineStrings: ["\"\"\""],
        atWords: .function, hashDirectives: true)

    static let python = CodeLanguage(
        keywords: words("""
            and as assert async await break class continue def del elif else except finally for from global if import \
            in is lambda nonlocal not or pass raise return try while with yield match case
            """),
        constants: words("True False None self cls"),
        builtinTypes: words("int float str bool list dict set tuple bytes object type"),
        lineComments: ["#"],
        strings: ["\"\"\"", "'''", "\"", "'"], multilineStrings: ["\"\"\"", "'''"],
        atWords: .function, indentsAfterColon: true)

    static let javascript = CodeLanguage(
        keywords: words(jsKeywords),
        constants: words("true false null undefined NaN Infinity"),
        lineComments: ["//"], blockComment: ("/*", "*/"),
        strings: ["\"", "'", "`"], multilineStrings: ["`"],
        atWords: .function)

    static let typescript = CodeLanguage(
        keywords: words(jsKeywords + """
             interface type enum implements namespace module declare abstract private protected public readonly \
            keyof infer is satisfies override
            """),
        constants: words("true false null undefined NaN Infinity"),
        builtinTypes: words("any unknown never string number boolean symbol object bigint"),
        lineComments: ["//"], blockComment: ("/*", "*/"),
        strings: ["\"", "'", "`"], multilineStrings: ["`"],
        atWords: .function)

    static let java = CodeLanguage(
        keywords: words("""
            abstract assert break case catch class continue default do else enum extends final finally for if \
            implements import instanceof interface native new package private protected public return static strictfp \
            super switch synchronized this throw throws transient try volatile while var record sealed permits yield
            """),
        constants: words("true false null"),
        builtinTypes: words("boolean byte char double float int long short void"),
        lineComments: ["//"], blockComment: ("/*", "*/"),
        strings: ["\"\"\"", "\"", "'"], multilineStrings: ["\"\"\""],
        atWords: .function)

    static let kotlin = CodeLanguage(
        keywords: words("""
            as break class continue do else for fun if in interface is object package return super this throw try \
            typealias val var when while by catch constructor finally get import init set where abstract annotation \
            companion const data enum expect actual external final infix inline inner internal lateinit open operator \
            out override private protected public reified sealed suspend tailrec vararg
            """),
        constants: words("true false null"),
        lineComments: ["//"], blockComment: ("/*", "*/"),
        strings: ["\"\"\"", "\"", "'"], multilineStrings: ["\"\"\""],
        atWords: .function)

    static let go = CodeLanguage(
        keywords: words("""
            break case chan const continue default defer else fallthrough for func go goto if import interface map \
            package range return select struct switch type var
            """),
        constants: words("true false nil iota"),
        builtinTypes: words("""
            bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 \
            uint16 uint32 uint64 uintptr any
            """),
        lineComments: ["//"], blockComment: ("/*", "*/"),
        strings: ["\"", "'", "`"], multilineStrings: ["`"], rawStrings: ["`"])

    static let rust = CodeLanguage(
        keywords: words("""
            as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move \
            mut pub ref return self Self static struct super trait type unsafe use where while
            """),
        constants: words("true false"),
        builtinTypes: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
        lineComments: ["//"], blockComment: ("/*", "*/"),
        strings: ["\""], multilineStrings: ["\""], rawStringPrefixes: ["r", "br", "cr"], charLiterals: true,
        bangMacros: true)

    private static let cKeywords = """
        auto break case const continue default do else enum extern for goto if inline register restrict return \
        sizeof static struct switch typedef union volatile while
        """
    private static let cTypes = """
        char double float int long short signed unsigned void bool size_t int8_t int16_t int32_t int64_t uint8_t \
        uint16_t uint32_t uint64_t
        """

    static let c = CodeLanguage(
        keywords: words(cKeywords),
        constants: words("NULL true false YES NO nil"),
        builtinTypes: words(cTypes),
        lineComments: ["//"], blockComment: ("/*", "*/"),
        atWords: .keyword, hashDirectives: true)

    static let cpp = CodeLanguage(
        keywords: words(cKeywords + """
             alignas alignof catch class concept consteval constexpr constinit const_cast co_await co_return co_yield \
            decltype delete dynamic_cast explicit export friend mutable namespace new noexcept operator override \
            final private protected public reinterpret_cast requires static_assert static_cast template this \
            thread_local throw try typeid typename using virtual
            """),
        constants: words("true false nullptr NULL"),
        builtinTypes: words(cTypes + " wchar_t char8_t char16_t char32_t"),
        lineComments: ["//"], blockComment: ("/*", "*/"),
        rawStringPrefixes: ["R", "LR", "uR", "UR", "u8R"], hashDirectives: true)

    static let shell = CodeLanguage(
        keywords: words("""
            if then else elif fi case esac for select while until do done in function return exit break continue \
            local export readonly declare typeset unset shift source alias eval exec trap
            """),
        constants: words("true false"),
        lineComments: ["#"], commentsAfterSpace: true,
        multilineStrings: ["\"", "'"], rawStrings: ["'"], heredoc: .shell, backslashEscapes: true,
        capitalizedTypes: false, dollarVariables: true)

    static let ruby = CodeLanguage(
        keywords: words("""
            alias and begin break case class def do else elsif end ensure for if in module next not or redo rescue \
            retry return self super then undef unless until when while yield require require_relative include extend \
            attr_accessor attr_reader attr_writer private protected public lambda proc puts
            """),
        constants: words("true false nil"),
        lineComments: ["#"],
        multilineStrings: ["\"", "'"], heredoc: .ruby,
        dollarVariables: true, atWords: .property)

    static let php = CodeLanguage(
        keywords: words("""
            abstract and array as break callable case catch class clone const continue declare default do echo else \
            elseif empty extends final finally fn for foreach function global goto if implements include include_once \
            instanceof insteadof interface isset list match namespace new or print private protected public readonly \
            require require_once return static switch throw trait try unset use var while xor yield
            """),
        constants: words("true false null TRUE FALSE NULL"),
        lineComments: ["//", "#"], blockComment: ("/*", "*/"),
        multilineStrings: ["\"", "'"], heredoc: .php,
        dollarVariables: true)

    static let sql = CodeLanguage(
        keywords: words("""
            select from where and or not insert into values update set delete create table drop alter add column \
            index primary key foreign references join inner left right outer full cross on as group by order having \
            limit offset distinct union all case when then else end is like ilike in between exists default \
            constraint unique check view begin commit rollback transaction with recursive returning asc desc if \
            replace grant revoke truncate
            """),
        constants: words("true false null"),
        builtinTypes: words("""
            int integer bigint smallint decimal numeric real float double varchar char text date time timestamp \
            boolean blob json jsonb serial uuid
            """),
        lineComments: ["--"], blockComment: ("/*", "*/"),
        // MySQL dumps write 'O\'Brien'; now that strings span lines, a literal backslash there would
        // turn the rest of the dump into one string. Only a string ending in "\" pays for this.
        strings: ["'", "\""], multilineStrings: ["'", "\""],
        caseInsensitive: true, capitalizedTypes: false)

    static let json = CodeLanguage(
        constants: words("true false null"),
        lineComments: ["//"], blockComment: ("/*", "*/"),
        strings: ["\""],
        capitalizedTypes: false, keyedStrings: true)

    static let yaml = CodeLanguage(
        constants: words("true false null yes no on off"),
        lineComments: ["#"], commentsAfterSpace: true, rawStrings: ["'"], blockScalars: true,
        capitalizedTypes: false, keyedStrings: true, keySeparator: 0x3A, hyphenatedWords: true,
        indentsAfterColon: true)

    static let toml = CodeLanguage(
        constants: words("true false"),
        lineComments: ["#", ";"],
        strings: ["\"\"\"", "'''", "\"", "'"], multilineStrings: ["\"\"\"", "'''"], rawStrings: ["'''", "'"],
        capitalizedTypes: false, keySeparator: 0x3D, hyphenatedWords: true)

    static let css = CodeLanguage(
        keywords: words("important"),
        blockComment: ("/*", "*/"),
        capitalizedTypes: false, keySeparator: 0x3A, hyphenatedWords: true,
        atWords: .keyword)

    static let scss: CodeLanguage = {
        var scss = css
        scss.lineComments = ["//"]
        scss.commentsAfterSpace = true
        return scss
    }()

    static let markupLanguage = CodeLanguage(markup: true)
}

/// `text` as a comment on a line of its own in language `id` (a `CodeLanguage.named` id), safe to drop
/// into the code: line breaks become spaces, and what would end the comment early is broken up
/// (`*/`, `--` in markup, a backslash ending a C line, PHP's `?>`). Nil for JSON and languages
/// without comments.
func commentLine(_ text: String, language id: String) -> String? {
    guard id != "json", let language = CodeLanguage.named(id) else { return nil }
    let breaks = CharacterSet.newlines.union(.controlCharacters)
    var text = String(String.UnicodeScalarView(text.unicodeScalars.map { breaks.contains($0) ? " " : $0 }))
    if language.markup {
        while text.contains("--") { text = text.replacingOccurrences(of: "--", with: "- -") }
        return "<!-- \(text) -->"
    }
    if let marker = language.lineComments.first {
        // C and C++ splice a line that ends in a backslash onto the next one.
        if id == "c" || id == "cpp" { while text.hasSuffix("\\") { text.removeLast() } }
        // PHP leaves code at `?>`, in a comment too.
        if id == "php" { text = text.replacingOccurrences(of: "?>", with: "? >") }
        return "\(marker) \(text)"
    }
    guard let block = language.blockComment else { return nil }
    let broken = text.replacingOccurrences(of: block.close, with: block.close.map(String.init).joined(separator: " "))
    return "\(block.open) \(broken) \(block.close)"
}

/// Where a comment line goes to sit above line `line` (1-based) of `text` in language `id` without
/// breaking anything, and what to insert there. The spot moves up while that line starts inside a
/// multi-line string, comment or tag, or continues the line above (`\`); and below a first line
/// something else reads (`#!`, `<?xml`, a Python coding line). The comment takes that line's
/// indentation (the next non-blank line's, for a blank one) and the file's line ending, and among
/// JSX children a `// …` comment becomes `{/* … */}`.
func commentInsertion(_ comment: String, aboveLine line: Int, in text: String, language id: String) -> (location: Int, text: String) {
    let source = text as NSString
    var starts = [0]
    while case let newline = source.range(of: "\n", options: .literal,
                                           range: NSRange(location: starts.last!, length: source.length - starts.last!)),
          newline.location != NSNotFound {
        starts.append(NSMaxRange(newline))
    }
    func content(_ index: Int) -> String {
        let end = index + 1 < starts.count ? starts[index + 1] : source.length
        return source.substring(with: NSRange(location: starts[index], length: end - starts[index])).trimmingCharacters(in: .newlines)
    }
    func lineIndex(of offset: Int) -> Int { starts.lastIndex { $0 <= offset } ?? 0 }

    var firstFree = ["#!", "<?xml", "<?php"].contains { content(0).hasPrefix($0) } ? 1 : 0
    for index in 0..<min(2, starts.count) where content(index).range(of: #"^[ \t\f]*#.*coding[:=]"#, options: .regularExpression) != nil {
        firstFree = index + 1
    }
    let language = CodeLanguage.named(id)
    let tokens = language.map { tokenize(text, as: $0) } ?? []
    func isCode(_ offset: Int) -> Bool {
        !tokens.contains { [.string, .comment].contains($0.kind) && NSLocationInRange(offset, $0.range) }
    }
    /// The last `mark` before `offset` that is code: an attribute value may hold `<` and `>`.
    func last(_ mark: String, before offset: Int) -> Int {
        var end = offset
        while case let found = source.range(of: mark, options: .backwards, range: NSRange(location: 0, length: end)).location,
              found != NSNotFound {
            if isCode(found) { return found }
            end = found
        }
        return NSNotFound
    }
    var index = min(max(line - 1, firstFree), starts.count - 1)
    while index > firstFree {
        let start = starts[index]
        if let token = tokens.first(where: { [.string, .comment].contains($0.kind) && $0.range.location < start && start < NSMaxRange($0.range) }) {
            index = max(lineIndex(of: token.range.location), firstFree)
        } else if language?.markup == true,
                  case let open = last("<", before: start), open != NSNotFound,
                  case let close = last(">", before: start),
                  close == NSNotFound || close < open {
            index = max(lineIndex(of: open), firstFree)
        } else if content(index - 1).hasSuffix("\\") {
            index -= 1
        } else {
            break
        }
    }
    let newline = source.range(of: "\r\n").location == NSNotFound ? "\n" : "\r\n"
    // A file that is all first line: the comment goes after it, on a line of its own.
    if index < firstFree {
        // UTF-16: "\r\n" is one Character, and that doesn't end in "\n".
        return (source.length, (text.utf16.last == 0x0A ? "" : newline) + comment + newline)
    }
    var indentLine = index
    while indentLine + 1 < starts.count, content(indentLine).allSatisfy({ $0 == " " || $0 == "\t" }) { indentLine += 1 }
    let indent = String(content(indentLine).prefix { $0 == " " || $0 == "\t" })
    /// Whether the comment lands among JSX children, where `//` would be text on the page: the
    /// line closes a tag, or the nearest less-indented line above ends an opening tag and nothing
    /// opened since (a `{`, another tag) is still open. Anything less sure is code.
    /// shortcut: indentation stands in for parsing JSX, so oddly indented children keep `//`; parse it if that bites.
    func insideJSXChildren() -> Bool {
        if content(indentLine).dropFirst(indent.count).hasPrefix("</") { return true }
        var parent = index - 1
        while parent >= 0, content(parent).prefix(indent.count).allSatisfy({ $0 == " " || $0 == "\t" }) { parent -= 1 }
        guard parent >= 0, case let head = content(parent).trimmingCharacters(in: .whitespaces),
              head.hasSuffix(">"), !head.hasSuffix("/>"), !head.hasSuffix("=>") else { return false }
        let close = source.range(of: ">", options: .backwards, range: NSRange(location: 0, length: starts[parent + 1])).location
        // A tag follows space or punctuation: the `<` of `Array<T>` and `a <b` follows a word.
        guard isCode(close), case let open = last("<", before: close), open != NSNotFound,
              source.substring(with: NSRange(location: max(open - 1, 0), length: min(open, 1) + 2))
                  .range(of: #"^[^\w)\]]?<[A-Za-z>]$"#, options: .regularExpression) != nil else { return false }
        var depth = 0, tagOpen = false
        for offset in close..<starts[index] {
            let c = source.character(at: offset)
            guard [0x7B, 0x7D, 0x3C, 0x3E].contains(c), isCode(offset) else { continue }
            if c == 0x7B || c == 0x7D {
                depth += c == 0x7B ? 1 : -1
            } else if depth == 0 {
                tagOpen = c == 0x3C && (0x61...0x7A).contains(source.character(at: offset + 1) | 0x20)
            }
        }
        return depth == 0 && !tagOpen
    }
    var comment = comment
    if id == "javascript" || id == "typescript", comment.hasPrefix("// "), insideJSXChildren() {
        comment = "{/* " + comment.dropFirst(3).replacingOccurrences(of: "*/", with: "* /") + " */}"
    }
    return (starts[index], indent + comment + newline)
}

/// Splits source into colored tokens, sorted and non-overlapping. One pass over UTF-16, so the
/// ranges are the ones `NSString` and TextKit use.
func tokenize(_ text: String, as language: CodeLanguage) -> [SyntaxToken] {
    var scanner = CodeScanner(units: Array(text.utf16), language: language)
    return language.markup ? scanner.scanMarkup() : scanner.scanCode()
}

/// The text as HTML lines with `tk-` spans. A token that crosses a line break is split at it, so
/// every line stands on its own (the preview numbers them).
func highlightedLines(_ text: String, language: CodeLanguage?) -> [String] {
    let source = text as NSString
    let tokens = language.map { tokenize(text, as: $0) } ?? []
    var lines: [String] = []
    var first = 0
    var start = 0
    repeat {
        let newline = source.range(of: "\n", options: .literal, range: NSRange(location: start, length: source.length - start))
        let end = newline.location == NSNotFound ? source.length : newline.location
        var html = "", written = start
        while first < tokens.count, NSMaxRange(tokens[first].range) <= start { first += 1 }
        var index = first
        while index < tokens.count, tokens[index].range.location < end {
            let token = tokens[index]
            let from = max(token.range.location, start), to = min(NSMaxRange(token.range), end)
            if from > written { html += escapeHTML(source.substring(with: NSRange(location: written, length: from - written))) }
            if to > from {
                html += "<span class=\"\(token.kind.cssClass)\">"
                    + escapeHTML(source.substring(with: NSRange(location: from, length: to - from))) + "</span>"
            }
            written = max(written, to)
            index += 1
        }
        if end > written { html += escapeHTML(source.substring(with: NSRange(location: written, length: end - written))) }
        lines.append(html)
        start = end + 1
    } while start <= source.length
    return lines
}

func highlightedHTML(_ text: String, language: CodeLanguage?) -> String {
    highlightedLines(text, language: language).joined(separator: "\n")
}

/// One pass: the preview escapes every token, so four `replacingOccurrences` copies each added up.
func escapeHTML(_ text: String) -> String {
    var html = ""
    html.reserveCapacity(text.utf8.count)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": html += "&amp;"
        case "<": html += "&lt;"
        case ">": html += "&gt;"
        case "\"": html += "&quot;"
        default: html.unicodeScalars.append(scalar)
        }
    }
    return html
}

func unescapeHTML(_ html: String) -> String {
    html.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}

private extension String {
    func leftPadded(to width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}

private struct CodeScanner {
    let units: [UInt16]
    let language: CodeLanguage
    var tokens: [SyntaxToken] = []

    private static let (newline, tab, space, quote, apostrophe) = (UInt16(0x0A), UInt16(0x09), UInt16(0x20), UInt16(0x22), UInt16(0x27))
    private static let (hash, dollar, dot, plus, minus, slash) = (UInt16(0x23), UInt16(0x24), UInt16(0x2E), UInt16(0x2B), UInt16(0x2D), UInt16(0x2F))
    private static let (colon, less, greater, question, at, bang) = (UInt16(0x3A), UInt16(0x3C), UInt16(0x3E), UInt16(0x3F), UInt16(0x40), UInt16(0x21))
    private static let (backslash, openParen, openBrace, closeBrace, ampersand, semicolon) = (UInt16(0x5C), UInt16(0x28), UInt16(0x7B), UInt16(0x7D), UInt16(0x26), UInt16(0x3B))
    private static let (carriageReturn, closeParen, pipe, tilde) = (UInt16(0x0D), UInt16(0x29), UInt16(0x7C), UInt16(0x7E))

    private var count: Int { units.count }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
    private static func isWordStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0xC0
    }
    private static func isWordChar(_ c: UInt16) -> Bool { isWordStart(c) || isDigit(c) }

    private func matches(_ needle: [UInt16], at i: Int, ignoringCase: Bool = false) -> Bool {
        guard i + needle.count <= count else { return false }
        for k in needle.indices {
            let a = units[i + k], b = needle[k]
            if a != b && !(ignoringCase && a | 0x20 == b | 0x20) { return false }
        }
        return true
    }

    private mutating func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
        tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind))
    }

    private func endOfLine(from i: Int) -> Int {
        var j = i
        while j < count, units[j] != Self.newline { j += 1 }
        return j
    }

    private func endOfWord(from i: Int) -> Int {
        var j = i
        while j < count, Self.isWordChar(units[j])
                || (language.hyphenatedWords && units[j] == Self.minus && j + 1 < count && Self.isWordChar(units[j + 1])) {
            j += 1
        }
        return j
    }

    private func nextNonBlank(from i: Int) -> UInt16? {
        var j = i
        while j < count, units[j] == Self.space || units[j] == Self.tab { j += 1 }
        return j < count ? units[j] : nil
    }

    private static let specialParameters = Set("#?@*$!-0123456789".utf16)

    /// `'a'`, `'\n'`, `'\u{1F980}'` or `'🦀'`: one character or escape between quotes. Anything
    /// else after a `'` (Rust's `'a` lifetimes) isn't a literal.
    private func charLiteralEnd(from i: Int) -> Int? {
        var j = i + 1
        guard j < count else { return nil }
        if units[j] == Self.backslash {
            j += 2
            while j < count, j - i < 12, units[j] != Self.apostrophe, units[j] != Self.newline { j += 1 }
        } else {
            j += UTF16.isLeadSurrogate(units[j]) ? 2 : 1
        }
        return j < count && units[j] == Self.apostrophe ? j + 1 : nil
    }

    private func endOfString(from i: Int, closing delimiter: [UInt16], spansLines: Bool, raw: Bool) -> Int {
        var j = i
        while j < count {
            if units[j] == Self.backslash, !raw { j += 2; continue }
            if matches(delimiter, at: j) { return j + delimiter.count }
            if units[j] == Self.newline && !spansLines { return j }
            j += 1
        }
        return count
    }

    /// Where the raw string whose prefix (`r`, `u8R`) ends at `i` closes: Rust's `r#"…"#` at as
    /// many `#`, C++'s `R"x(…)x"` at the same `x`. Nil when no string opens there (`r#type`).
    private func endOfRawString(from i: Int) -> Int? {
        var j = i
        while j < count, units[j] == Self.hash { j += 1 }
        guard j < count, units[j] == Self.quote else { return nil }
        var closing = [Self.quote] + units[i..<j]
        if units[i - 1] == 0x52 {
            var paren = j + 1
            while paren < count, ![Self.openParen, Self.quote, Self.newline].contains(units[paren]) { paren += 1 }
            guard paren < count, units[paren] == Self.openParen else { return nil }
            closing = [Self.closeParen] + units[(j + 1)..<paren] + [Self.quote]
            j = paren
        }
        j += 1
        while j < count, !matches(closing, at: j) { j += 1 }
        return min(count, j + closing.count)
    }

    /// The word a here-document opener at `i` names (`<<EOF`, `<<-'EOF'`, `<<~SQL`, `<<<"EOT"`),
    /// whether its closing line may be indented, and where the opener ends.
    private func heredocOpener(at i: Int, _ style: CodeLanguage.Heredoc) -> (word: [UInt16], indented: Bool, end: Int)? {
        let php = style == .php, ruby = style == .ruby
        var j = i + (php ? 3 : 2)
        // `<<<` in a shell is a here-string, and Ruby's `1<<N` shifts.
        guard matches(Array(repeating: Self.less, count: j - i), at: i), i == 0 || units[i - 1] != Self.less,
              !(ruby && i > 0 && Self.isWordChar(units[i - 1])) else { return nil }
        var indented = php
        if !php, j < count, units[j] == Self.minus || units[j] == Self.tilde { indented = true; j += 1 }
        // Ruby's `a << b` appends.
        if !ruby { while j < count, units[j] == Self.space || units[j] == Self.tab { j += 1 } }
        if style == .shell, j < count, units[j] == Self.backslash { j += 1 }
        let quoted = j < count && (units[j] == Self.quote || units[j] == Self.apostrophe)
        let start = quoted ? j + 1 : j
        // shortcut: the word is an identifier, so `<<END-1` and `<<!` open nothing; widen it if such scripts turn up.
        guard start < count, Self.isWordStart(units[start]) else { return nil }
        let end = endOfWord(from: start)
        if quoted, !(end < count && units[end] == units[j]) { return nil }
        // Ruby's `x <<y` appends and `class <<self` opens a class: a bare word is upper case.
        if ruby, !indented, !quoted, !Self.isUpper(units[start]) { return nil }
        if style == .shell, insideArithmetic(i) { return nil }
        return (Array(units[start..<end]), indented, quoted ? end + 1 : end)
    }

    /// Shell: after a `((` still open on its line, `<<` shifts bits.
    private func insideArithmetic(_ i: Int) -> Bool {
        var j = i - 1
        while j > 0, units[j] != Self.newline {
            if units[j] == units[j - 1], units[j] == Self.closeParen { return false }
            if units[j] == units[j - 1], units[j] == Self.openParen { return true }
            j -= 1
        }
        return false
    }

    /// Where the here-document whose text starts after the line break at `i` ends: after `word`
    /// on the line that closes it.
    private func endOfHeredoc(from i: Int, word: [UInt16], indented: Bool) -> Int {
        var end = i
        while end < count {
            var start = end + 1
            end = endOfLine(from: start)
            if indented { while start < end, units[start] == Self.space || units[start] == Self.tab { start += 1 } }
            guard matches(word, at: start) else { continue }
            let after = start + word.count
            let rest = after < end ? units[after] : Self.newline
            // PHP's closing line may go on (`EOT;`); a shell or Ruby one is the word alone.
            if language.heredoc == .php ? !Self.isWordChar(rest) : rest == Self.newline || (rest == Self.carriageReturn && after + 1 == end) {
                return after
            }
        }
        return count
    }

    /// Where the text of the YAML block scalar opened at `i` (`key: |`, `- >-`) ends: the last
    /// of the lines after it that are blank or indented deeper than its key. Nil when `i` opens none.
    private func endOfBlockScalar(at i: Int) -> Int? {
        var j = i + 1
        while j < count, units[j] == Self.plus || units[j] == Self.minus || Self.isDigit(units[j]) { j += 1 }
        guard i > 0, units[i - 1] == Self.space || units[i - 1] == Self.tab,
              [nil, Self.newline, Self.carriageReturn, Self.hash].contains(nextNonBlank(from: j)) else { return nil }
        var start = i
        while start > 0, units[start - 1] != Self.newline { start -= 1 }
        // The key's column, past any `- `; a scalar that is the list item itself only has to pass its dash.
        var key = start
        while key < i, units[key] == Self.space || (units[key] == Self.minus && units[key + 1] == Self.space) { key += 1 }
        let indent = key - start - (key == i ? 1 : 0)
        var end: Int? = nil
        var line = endOfLine(from: j)
        while line < count {
            var text = line + 1
            while text < count, units[text] == Self.space { text += 1 }
            let lineEnd = endOfLine(from: text)
            if text < lineEnd, !(units[text] == Self.carriageReturn && text + 1 == lineEnd) {
                guard text - line - 1 > indent else { break }
                end = lineEnd
            }
            line = lineEnd
        }
        return end
    }

    mutating func scanCode() -> [SyntaxToken] {
        let lineComments = language.lineComments.map { Array($0.utf16) }
        let block = language.blockComment.map { (Array($0.open.utf16), Array($0.close.utf16)) }
        let delimiters = language.strings.map { Array($0.utf16) }
        let spanning = Set(language.multilineStrings.map { Array($0.utf16) })
        let raw = Set(language.rawStrings.map { Array($0.utf16) })
        var i = 0
        var atLineStart = true
        // Where here-document or block-scalar text opened on this line ends. It is one string from
        // the line break on, so that each of its lines, the first too, starts inside the token.
        var textEnd: Int? = nil
        while i < count {
            let c = units[i]
            if c == Self.newline {
                if let end = textEnd.take(), end > i { add(i, end, .string); i = end; continue }
                atLineStart = true; i += 1; continue
            }
            if c == Self.space || c == Self.tab { i += 1; continue }
            let lineStart = atLineStart
            atLineStart = false
            if language.backslashEscapes, c == Self.backslash, i + 1 < count, units[i + 1] != Self.newline { i += 2; continue }
            // YAML list items: `- key: value` still starts a key.
            if lineStart, language.keySeparator != nil, c == Self.minus, i + 1 < count, units[i + 1] == Self.space {
                atLineStart = true; i += 1; continue
            }
            if let marker = lineComments.first(where: { matches($0, at: i) }),
               !language.commentsAfterSpace || lineStart || units[i - 1] == Self.space || units[i - 1] == Self.tab {
                let end = endOfLine(from: i + marker.count)
                add(i, end, .comment); i = end; continue
            }
            if let block, matches(block.0, at: i) {
                var j = i + block.0.count
                while j < count, !matches(block.1, at: j) { j += 1 }
                j = min(count, j + block.1.count)
                add(i, j, .comment); i = j; continue
            }
            if language.charLiterals, c == Self.apostrophe, let end = charLiteralEnd(from: i) {
                add(i, end, .string); i = end; continue
            }
            if let delimiter = delimiters.first(where: { matches($0, at: i) }) {
                let escapes = !raw.contains(delimiter) || (language.backslashEscapes && i > 0 && units[i - 1] == Self.dollar)
                let end = min(count, endOfString(from: i + delimiter.count, closing: delimiter,
                                                 spansLines: spanning.contains(delimiter), raw: !escapes))
                add(i, end, language.keyedStrings && nextNonBlank(from: end) == Self.colon ? .property : .string)
                i = end; continue
            }
            if let style = language.heredoc, c == Self.less, let opener = heredocOpener(at: i, style) {
                textEnd = endOfHeredoc(from: endOfLine(from: textEnd ?? opener.end), word: opener.word, indented: opener.indented)
                i = opener.end; continue
            }
            if language.hashDirectives, c == Self.hash, i + 1 < count, Self.isWordStart(units[i + 1]) {
                let end = endOfWord(from: i + 1)
                add(i, end, .keyword); i = end; continue
            }
            if Self.isDigit(c) || (c == Self.dot && i + 1 < count && Self.isDigit(units[i + 1])) {
                // 0x1F, 1_000, 1e-3, 1'000, 2.5f; not the `.max` of `1.max()` or the `-1` of `0x1E-1`.
                let hex = c == 0x30 && i + 1 < count && units[i + 1] | 0x20 == 0x78
                var j = i + 1
                while j < count {
                    let d = units[j]
                    let digitFollows = j + 1 < count && Self.isDigit(units[j + 1])
                    let exponentSign = !hex && (d == Self.plus || d == Self.minus) && units[j - 1] | 0x20 == 0x65
                    let separator = (d == Self.dot || d == Self.apostrophe) && digitFollows
                    guard (d < 0x80 && Self.isWordChar(d)) || separator || exponentSign else { break }
                    j += 1
                }
                add(i, j, .number); i = j; continue
            }
            // Shell's `$#`, `$?`, `$1` and the like.
            if language.dollarVariables, c == Self.dollar, i + 1 < count, Self.specialParameters.contains(units[i + 1]) {
                add(i, i + 2, .property); i += 2; continue
            }
            if language.dollarVariables, c == Self.dollar, i + 1 < count,
               Self.isWordStart(units[i + 1]) || units[i + 1] == Self.openBrace {
                var j = i + 1
                if units[j] == Self.openBrace {
                    while j < count, units[j] != Self.closeBrace, units[j] != Self.newline { j += 1 }
                    j = min(count, j + 1)
                } else {
                    j = endOfWord(from: j)
                }
                add(i, j, .property); i = j; continue
            }
            if let kind = language.atWords, c == Self.at, i + 1 < count, Self.isWordStart(units[i + 1]) {
                let end = endOfWord(from: i + 1)
                add(i, end, kind); i = end; continue
            }
            if Self.isWordStart(c) {
                let end = endOfWord(from: i)
                let word = String(decoding: units[i..<end], as: UTF16.self)
                if language.rawStringPrefixes.contains(word), let close = endOfRawString(from: end) {
                    add(i, close, .string); i = close; continue
                }
                let key = language.caseInsensitive ? word.lowercased() : word
                let next: UInt16 = end < count ? units[end] : 0
                // After a `.`, `get`, `default` and `match` are member names, not keywords (but `...rest` isn't a member).
                let reserved = !(i > 0 && units[i - 1] == Self.dot && !(i > 1 && units[i - 2] == Self.dot))
                let kind: TokenKind? =
                    if reserved, language.keywords.contains(key) { .keyword }
                    else if reserved, language.constants.contains(key) { .constant }
                    else if reserved, language.builtinTypes.contains(key) { .type }
                    else if lineStart, let separator = language.keySeparator, nextNonBlank(from: end) == separator { .property }
                    else if next == Self.openParen || (language.bangMacros && next == Self.bang) { .function }
                    else if language.capitalizedTypes, Self.isUpper(c), end - i > 1 { .type }
                    else { nil }
                if let kind { add(i, end, kind) }
                i = end; continue
            }
            if language.blockScalars, c == Self.pipe || c == Self.greater, let end = endOfBlockScalar(at: i) { textEnd = end }
            i += 1
        }
        return tokens
    }

    /// HTML and XML: tags, attributes, attribute values, comments and entities, with `<script>`
    /// and `<style>` contents colored as JavaScript and CSS.
    mutating func scanMarkup() -> [SyntaxToken] {
        let commentOpen = Array("<!--".utf16), commentClose = Array("-->".utf16)
        var i = 0
        while i < count {
            if matches(commentOpen, at: i) {
                var j = i + commentOpen.count
                while j < count, !matches(commentClose, at: j) { j += 1 }
                j = min(count, j + commentClose.count)
                add(i, j, .comment); i = j; continue
            }
            // A tag name is ASCII: `<한`, `<—` and `<😀` in text aren't tags.
            let startsTag = units[i] == Self.less && i + 1 < count
                && ((units[i + 1] < 0x80 && Self.isWordStart(units[i + 1])) || [Self.slash, Self.bang, Self.question].contains(units[i + 1]))
            guard startsTag else {
                if units[i] == Self.ampersand, let end = entityEnd(from: i) { add(i, end, .constant); i = end; continue }
                i += 1; continue
            }
            var j = i + 1
            let closing = units[j] == Self.slash
            if [Self.slash, Self.bang, Self.question].contains(units[j]) { j += 1 }
            let nameStart = j
            while j < count, Self.isWordChar(units[j]) || [Self.minus, Self.colon, Self.dot].contains(units[j]) { j += 1 }
            let name = String(decoding: units[nameStart..<j], as: UTF16.self).lowercased()
            if j > nameStart { add(nameStart, j, .tag) }
            while j < count, units[j] != Self.greater {
                let c = units[j]
                if c == Self.quote || c == Self.apostrophe {
                    var k = j + 1
                    while k < count, units[k] != c { k += 1 }
                    k = min(count, k + 1)
                    add(j, k, .string); j = k
                } else if Self.isWordStart(c) || c == Self.at || c == Self.colon {
                    var k = j + 1
                    while k < count, Self.isWordChar(units[k]) || [Self.minus, Self.colon, Self.dot].contains(units[k]) { k += 1 }
                    add(j, k, .attribute); j = k
                } else {
                    j += 1
                }
            }
            i = min(count, j + 1)
            let embedded: CodeLanguage? = closing ? nil : name == "script" ? .javascript : name == "style" ? .css : nil
            if let embedded {
                let closeTag = Array("</\(name)".utf16)
                var end = i
                while end < count, !matches(closeTag, at: end, ignoringCase: true) { end += 1 }
                var inner = CodeScanner(units: Array(units[i..<end]), language: embedded)
                for token in inner.scanCode() {
                    tokens.append(SyntaxToken(range: NSRange(location: token.range.location + i, length: token.range.length), kind: token.kind))
                }
                i = end
            }
        }
        return tokens
    }

    private func entityEnd(from i: Int) -> Int? {
        var j = i + 1
        while j < count, j - i <= 10, Self.isWordChar(units[j]) || units[j] == Self.hash { j += 1 }
        return j < count && units[j] == Self.semicolon && j > i + 1 ? j + 1 : nil
    }
}
