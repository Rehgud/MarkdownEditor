import Foundation

/// Every format the app creates or edits, one row each. The Finder "새 파일" menu, new-file
/// templates, editor highlighting and the preview all read this table.
struct FileFormat: Hashable, Identifiable, Sendable {
    enum PreviewStyle: Hashable, Sendable {
        case markdown
        /// The HTML file itself, rendered as a page.
        case page
        /// Delimited text as a table, split on this separator.
        case table(Character)
        /// Highlighted code with line numbers, like a Notion code block.
        case code
        /// Plain text set as readable prose.
        case text
    }

    let name: String
    /// The first one names new files.
    let extensions: [String]
    /// A `CodeLanguage.named` id for highlighting; nil for Markdown and plain text.
    let language: String?
    let preview: PreviewStyle
    var template = ""

    var id: String { extensions[0] }
    var fileExtension: String { extensions[0] }
    var isMarkdown: Bool { preview == .markdown }

    /// The format the user declared for files like `url` wins (`declared`, or the saved choice when
    /// nil); then the extension. Untitled documents are Markdown, unknown extensions plain text.
    init(url: URL?, declared: String? = nil) {
        guard let url else { self = .markdown; return }
        let choice = declared ?? UserDefaults.standard.string(forKey: Self.declarationKey(for: url))
        if let choice, let format = Self.all.first(where: { $0.id == choice }) { self = format; return }
        let kind = Self.kind(of: url)
        self = Self.all.first { $0.extensions.contains(kind) } ?? .text
    }

    /// Where a declaration is saved: per extension, or per name for files without one (`Makefile`).
    static func declarationKey(for url: URL) -> String { "format." + kind(of: url) }

    /// The extension, or the whole name when there's none: Foundation gives `.zshrc` no extension.
    private static func kind(of url: URL) -> String {
        (url.pathExtension.isEmpty ? url.lastPathComponent : url.pathExtension).lowercased()
    }

    private init(name: String, extensions: [String], language: String?, preview: PreviewStyle, template: String = "") {
        self.name = name
        self.extensions = extensions
        self.language = language
        self.preview = preview
        self.template = template
    }

    static let markdown = FileFormat(name: "Markdown", extensions: ["md", "markdown", "mdown"], language: nil, preview: .markdown)
    static let text = FileFormat(name: String(localized: "텍스트"), extensions: ["txt", "text", "log"], language: nil, preview: .text)

    /// What people and developers make most, first in the 새 파일 menus; the rest are under 더보기.
    static let common = [markdown] + creatable.prefix(8)
    static let more = Array(creatable.dropFirst(8))

    /// The formats the 새 파일 menus make (Markdown aside), common ones first.
    static let creatable: [FileFormat] = [
        text,
        FileFormat(name: "Python", extensions: ["py", "pyw"], language: "python", preview: .code),
        FileFormat(name: "JavaScript", extensions: ["js", "mjs", "cjs", "jsx"], language: "javascript", preview: .code),
        FileFormat(name: "TypeScript", extensions: ["ts", "tsx", "mts", "cts"], language: "typescript", preview: .code),
        FileFormat(name: "HTML", extensions: ["html", "htm"], language: "html", preview: .page, template: """
            <!doctype html>
            <html lang="\(Bundle.main.preferredLocalizations[0])">
            <head>
              <meta charset="utf-8">
              <title>\(String(localized: "새 페이지"))</title>
            </head>
            <body>

            </body>
            </html>

            """),
        FileFormat(name: "CSS", extensions: ["css"], language: "css", preview: .code),
        FileFormat(name: "JSON", extensions: ["json", "jsonc"], language: "json", preview: .code, template: "{\n  \n}\n"),
        FileFormat(name: "CSV", extensions: ["csv"], language: nil, preview: .table(","), template: String(localized: "이름,값") + "\n"),
        FileFormat(name: "Java", extensions: ["java"], language: "java", preview: .code),
        FileFormat(name: "Swift", extensions: ["swift"], language: "swift", preview: .code),
        FileFormat(name: "Go", extensions: ["go"], language: "go", preview: .code),
        FileFormat(name: "Rust", extensions: ["rs"], language: "rust", preview: .code),
        FileFormat(name: "C", extensions: ["c", "h"], language: "c", preview: .code),
        FileFormat(name: "C++", extensions: ["cpp", "cc", "cxx", "hpp", "hh"], language: "cpp", preview: .code),
        FileFormat(name: String(localized: "셸 스크립트"), extensions: ["sh", "zsh", "bash", ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile"],
                   language: "shell", preview: .code, template: "#!/bin/zsh\n\n"),
        FileFormat(name: "YAML", extensions: ["yaml", "yml"], language: "yaml", preview: .code),
        FileFormat(name: "SQL", extensions: ["sql"], language: "sql", preview: .code),
    ]

    /// Everything the app opens with a format of its own; the rest of plain text opens as `text`.
    static let all: [FileFormat] = [markdown] + creatable + [
        FileFormat(name: "TSV", extensions: ["tsv", "tab"], language: nil, preview: .table("\t")),
        FileFormat(name: "SCSS · Less", extensions: ["scss", "less", "sass"], language: "scss", preview: .code),
        FileFormat(name: "XML", extensions: ["xml"], language: "xml", preview: .code),
        FileFormat(name: "Kotlin", extensions: ["kt", "kts"], language: "kotlin", preview: .code),
        FileFormat(name: "Ruby", extensions: ["rb"], language: "ruby", preview: .code),
        FileFormat(name: "PHP", extensions: ["php"], language: "php", preview: .code),
        FileFormat(name: "Objective-C", extensions: ["m", "mm"], language: "c", preview: .code),
        FileFormat(name: "TOML", extensions: ["toml", "ini", "cfg"], language: "toml", preview: .code),
    ]
}
