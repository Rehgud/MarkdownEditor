import Foundation

/// What the preview shows for a file.
enum PreviewContent: Equatable {
    /// HTML for the app's own styled page; `style` is the body's class.
    case body(String, style: String)
    /// A complete HTML document, shown as itself.
    case page(String)
}

func renderPreview(_ text: String, as format: FileFormat) -> PreviewContent {
    switch format.preview {
    case .markdown: .body(renderMarkdown(text), style: "")
    case .page: .page(text)
    case .table(let separator): .body(renderTable(text, separator: separator), style: "wide")
    case .code: .body(renderCodeCard(text, format: format), style: "wide")
    case .text: .body(renderPlainText(text), style: "")
    }
}

/// A Notion-style code block: language label, line numbers, and every line tagged with its
/// source line so split-view scrolling stays in step.
private func renderCodeCard(_ text: String, format: FileFormat) -> String {
    let language = format.language.flatMap(CodeLanguage.named)
    var lines = highlightedLines(text, language: language)
    // The file's final newline ends its last line; it doesn't start an empty one.
    if lines.count > 1, lines.last == "" { lines.removeLast() }
    // A line number takes a comment (JSON has none).
    let commentable = format.language.flatMap { commentLine("", language: $0) } != nil
    var html = jsonStatus(text, format: format) + "<div class=\"code-card\(commentable ? " commentable" : "")\">"
        + "<div class=\"code-lang\">\(escapeHTML(format.name))</div>"
    for (index, line) in lines.enumerated() {
        let number = index + 1
        html += "<div class=\"code-line\" data-sourcepos=\"\(number):1-\(number):1\">"
            + "<span class=\"ln\">\(number)</span><span class=\"src\">\(line)</span></div>"
    }
    return html + "</div>"
}

/// JSON files say up front whether they parse, and where they don't. Comments and trailing commas
/// (tsconfig, VS Code settings) get a note, not an error.
private func jsonStatus(_ text: String, format: FileFormat) -> String {
    guard format.language == "json", !text.allSatisfy(\.isWhitespace) else { return "" }
    let data = Data(text.utf8)
    do {
        _ = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return "<div class=\"code-status ok\">✓ \(String(localized: "올바른 JSON"))</div>"
    } catch {
        if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .json5Allowed])) != nil {
            return "<div class=\"code-status note\">\(String(localized: "주석이나 끝 쉼표가 있는 JSON (JSONC)"))</div>"
        }
        // Foundation's reason is English; the line it names is what's worth showing.
        let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
        let place = reason.firstMatch(of: #/line (\d+)/#).map { String(localized: "\(String($0.1))번째 줄 근처") } ?? String(localized: "읽을 수 없음")
        return "<div class=\"code-status error\" title=\"\(escapeHTML(reason))\">\(String(localized: "JSON 오류 · \(place)"))</div>"
    }
}

/// The first row is the header. Rows keep the source line they start on, for scroll sync.
private func renderTable(_ text: String, separator: Character) -> String {
    let rows = parseDelimited(text, separator: separator)
    guard let header = rows.first else { return "" }
    let width = rows.map(\.fields.count).max() ?? 0
    func row(_ row: (line: Int, fields: [String]), cell: String) -> String {
        let cells = (0..<width).map { "<\(cell)>\($0 < row.fields.count ? escapeHTML(row.fields[$0]) : "")</\(cell)>" }
        return "<tr data-sourcepos=\"\(row.line):1-\(row.line):1\">\(cells.joined())</tr>"
    }
    return "<table class=\"data\"><thead>\(row(header, cell: "th"))</thead><tbody>"
        + rows.dropFirst().map { row($0, cell: "td") }.joined() + "</tbody></table>"
}

/// RFC 4180: quoted fields may hold separators, line breaks and doubled `""` quotes. TSV has no
/// quoting, so a `"` there is just a character. Blank lines aren't rows.
func parseDelimited(_ text: String, separator: Character) -> [(line: Int, fields: [String])] {
    let characters = Array(text)
    let quoting = separator == ","
    var rows: [(line: Int, fields: [String])] = [], fields: [String] = [], field = ""
    var quoted = false, rowQuoted = false, line = 1, rowLine = 1, i = 0
    func endRow() {
        if !fields.isEmpty || !field.isEmpty || rowQuoted { rows.append((rowLine, fields + [field])) }
        fields = []
        field = ""
        rowQuoted = false
    }
    while i < characters.count {
        let c = characters[i]
        if quoted {
            if c == "\"" {
                if i + 1 < characters.count, characters[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
            } else {
                if c.isNewline { line += 1 }
                field.append(c)
            }
        } else if quoting, c == "\"", field.isEmpty {
            quoted = true
            rowQuoted = true
        } else if c == separator {
            fields.append(field)
            field = ""
        } else if c.isNewline {
            endRow()
            line += 1
            rowLine = line
        } else {
            field.append(c)
        }
        i += 1
    }
    endRow()
    return rows
}

private func renderPlainText(_ text: String) -> String {
    let lines = text.components(separatedBy: "\n").enumerated().map { index, line in
        "<p data-sourcepos=\"\(index + 1):1-\(index + 1):1\">\(escapeHTML(line))</p>"
    }
    return "<div class=\"text-page\">\(lines.joined())</div>"
}
