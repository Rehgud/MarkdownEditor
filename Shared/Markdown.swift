import Foundation
import cmark_gfm
import cmark_gfm_extensions

struct MarkdownHeading {
    let level: Int
    let id: String
    let title: String
}

/// GFM to HTML with cmark-gfm, GitHub's own renderer. Shared by the app preview and Quick Look.
func renderMarkdown(_ markdown: String) -> String { highlightCodeBlocks(in: anchorHeadings(in: renderHTML(markdown)).html) }

/// The document's headings with the same ids the preview gives them, for /toc.
func markdownHeadings(_ markdown: String) -> [MarkdownHeading] { anchorHeadings(in: renderHTML(markdown)).headings }

/// GitHub-style heading ids ("설치 방법" → "설치-방법", repeats → "-1", "-2") so `#…` links land.
private func anchorHeadings(in html: String) -> (html: String, headings: [MarkdownHeading]) {
    // Setext headings can span lines.
    let tag = try! NSRegularExpression(pattern: "<h([1-6])([^>]*)>(.*?)</h\\1>", options: .dotMatchesLineSeparators)
    let source = html as NSString
    var output = "", headings: [MarkdownHeading] = [], used = Set<String>(), seen: [String: Int] = [:], copied = 0
    for match in tag.matches(in: html, range: NSRange(location: 0, length: source.length)) {
        let level = Int(source.substring(with: match.range(at: 1)))!
        // A raw `<h2 id="…">` keeps its own id.
        let rawID = source.substring(with: match.range(at: 2)).firstMatch(of: #/\sid\s*=\s*"([^"]*)"/#)?.1
        let inner = source.substring(with: match.range(at: 3))
        let title = unescapeHTML(inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        let slug = String(title.lowercased().compactMap { $0 == " " ? "-" : ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : nil })
        let base = slug.isEmpty ? "heading" : slug
        var repeats = seen[base, default: 0]
        var id = repeats == 0 ? base : "\(base)-\(repeats)"
        while used.contains(id) {
            repeats += 1
            id = "\(base)-\(repeats)"
        }
        if let rawID { id = String(rawID) } else { seen[base] = repeats + 1 }
        used.insert(id)
        headings.append(MarkdownHeading(level: level, id: id, title: title))
        output += source.substring(with: NSRange(location: copied, length: match.range.location - copied))
        output += rawID != nil ? source.substring(with: match.range)
            : "<h\(level) id=\"\(id)\"\(source.substring(with: match.range(at: 2)))>\(inner)</h\(level)>"
        copied = NSMaxRange(match.range)
    }
    return (output + source.substring(from: copied), headings)
}

/// cmark leaves code blocks plain; color the ones whose fence names a language we know, the way
/// a Notion code block does.
private func highlightCodeBlocks(in html: String) -> String {
    // cmark writes `<pre data-sourcepos="…" lang="swift">`, attributes in that order.
    let block = try! NSRegularExpression(pattern: "<pre([^>]*)><code>([\\s\\S]*?)</code></pre>")
    let lang = try! NSRegularExpression(pattern: "\\blang=\"([^\"]*)\"")
    let source = html as NSString
    var output = "", copied = 0
    for match in block.matches(in: html, range: NSRange(location: 0, length: source.length)) {
        let attributes = source.substring(with: match.range(at: 1)) as NSString
        guard let name = lang.firstMatch(in: attributes as String, range: NSRange(location: 0, length: attributes.length))
                .map({ attributes.substring(with: $0.range(at: 1)) }),
              let language = CodeLanguage.named(name) else { continue }
        let code = unescapeHTML(source.substring(with: match.range(at: 2)))
        output += source.substring(with: NSRange(location: copied, length: match.range.location - copied))
        output += "<pre\(attributes)><code>\(highlightedHTML(code, language: language))</code></pre>"
        copied = NSMaxRange(match.range)
    }
    return output + source.substring(from: copied)
}

private func renderHTML(_ markdown: String) -> String {
    cmark_gfm_core_extensions_ensure_registered()
    // UNSAFE keeps raw HTML like GitHub does; the CSP in previewHTML stops it running or loading anything.
    // SOURCEPOS tags blocks with their source lines, which split-view scroll sync maps through.
    let options = CMARK_OPT_DEFAULT | CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES | CMARK_OPT_GITHUB_PRE_LANG | CMARK_OPT_SOURCEPOS
    let parser = cmark_parser_new(options)!
    defer { cmark_parser_free(parser) }
    for name in ["table", "strikethrough", "autolink", "tasklist"] {
        cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
    }
    cmark_parser_feed(parser, markdown, markdown.utf8.count)
    let document = cmark_parser_finish(parser)!
    defer { cmark_node_free(document) }
    let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser))!
    defer { free(html) }
    return String(cString: html)
}

func previewHTML(body: String = "") -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><base href="">\
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src md-local: data: https: http:; style-src 'unsafe-inline'">\
    <style>\(previewCSS)</style></head>\
    <body>\(body)</body></html>
    """
}

/// Notion's palette and rhythm: warm gray text, 16px/1.5, quiet code blocks, square to-dos.
private let previewCSS = """
:root {
  color-scheme: light dark;
  --text: #37352f; --muted: rgba(55, 53, 47, .65); --bg: #fff;
  --divider: rgba(55, 53, 47, .16); --border: #e9e9e7; --block-bg: #f7f6f3;
  --inline-code: #eb5757; --inline-code-bg: rgba(135, 131, 120, .15);
  --accent: #2383e2; --underline: rgba(55, 53, 47, .4); --highlight: #fbf3db;
}
@media (prefers-color-scheme: dark) {
  :root {
    --text: rgba(255, 255, 255, .81); --muted: rgba(255, 255, 255, .46); --bg: #191919;
    --divider: rgba(255, 255, 255, .13); --border: #2f2f2f; --block-bg: #202020;
    --inline-code: #ff7369; --underline: rgba(255, 255, 255, .4); --highlight: #564328;
  }
}
html { background: var(--bg); }
body {
  max-width: 708px; margin: 0 auto; padding: 48px clamp(20px, 7vw, 96px) 30vh;
  font: 16px/1.5 ui-sans-serif, -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Segoe UI",
    Helvetica, "Apple Color Emoji", Arial, sans-serif;
  color: var(--text); -webkit-font-smoothing: antialiased; overflow-wrap: break-word;
}
::selection { background: rgba(35, 131, 226, .28); }
body > :first-child { margin-top: 0; }

h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.3; margin: 1.6em 0 .3em; }
h1 { font-size: 1.875em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; } h4, h5, h6 { font-size: 1em; }
body > h1:first-child { font-size: 2.5em; font-weight: 700; line-height: 1.2; margin-bottom: .5em; }
p, ul, ol, blockquote, table, pre, details { margin: .5em 0; }
strong { font-weight: 600; }
a { color: inherit; text-decoration: underline; text-decoration-color: var(--underline); text-underline-offset: .15em; }
a:hover { text-decoration-color: currentColor; }
mark { background: var(--highlight); color: inherit; border-radius: 3px; padding: 0 .15em; }
hr { border: 0; border-top: 1px solid var(--divider); margin: 1.25em 0; }
img { max-width: 100%; border-radius: 4px; }

ul, ol { padding-left: 1.625em; }
li { margin: .2em 0; }
li > ul, li > ol { margin: .1em 0; }
li:has(> input[type=checkbox], > p:first-child > input[type=checkbox]) { list-style: none; }
:is(li, li > p:first-child) > input[type=checkbox] {
  /* Floated so the space after it collapses and the strike-through starts at the text. */
  appearance: none; float: left; width: 16px; height: 16px; margin: .25em .5em 0 -1.5em;
  border: 1.5px solid var(--muted); border-radius: 3px;
}
:is(li, li > p:first-child) > input[type=checkbox]:checked {
  border-color: var(--accent);
  background: var(--accent) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4 8.5l2.5 2.5L12 5.5' fill='none' stroke='white' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / 14px no-repeat;
}
:is(li, li > p:first-child):has(> input[type=checkbox]:checked) { color: var(--muted); text-decoration: line-through; }
/* Inline-block stops a checked item's strike-through from reaching its nested items. */
li:has(> input[type=checkbox]:checked) > :is(ul, ol) { display: inline-block; width: 100%; box-sizing: border-box; color: var(--text); }

blockquote { padding: .1em 0 .1em .9em; border-left: 3px solid currentColor; }

code { font-family: "SFMono-Regular", ui-monospace, Menlo, Consolas, monospace; font-size: 85%; }
:not(pre) > code { color: var(--inline-code); background: var(--inline-code-bg); padding: .2em .4em; border-radius: 4px; }
pre { background: var(--block-bg); border-radius: 4px; padding: 1.25em 1.5em; overflow-x: auto; line-height: 1.6; tab-size: 2; }
pre[lang]::before { content: attr(lang); display: block; margin-bottom: .6em; font: 12px -apple-system, sans-serif; color: var(--muted); }

table { border-collapse: collapse; font-size: 14px; display: block; max-width: 100%; overflow-x: auto; }
th, td { border: 1px solid var(--border); padding: 7px 9px; vertical-align: top; }
th { background: var(--block-bg); font-weight: 600; }
th:not([align]) { text-align: left; }

details > summary { cursor: pointer; list-style: none; }
details > summary::-webkit-details-marker { display: none; }
details > summary::before { content: "\\25B6"; display: inline-block; width: 1em; margin-right: .5em; font-size: .7em; text-align: center; }
details[open] > summary::before { transform: rotate(90deg); }
details > :not(summary) { margin-left: 1.4em; }

.footnotes { margin-top: 3em; padding-top: 1em; border-top: 1px solid var(--divider); font-size: 14px; color: var(--muted); }
.footnote-backref { font-variant-emoji: text; text-decoration: none; }

/* Code and data files: full width, a Notion-style code card, readable plain text. */
body.wide { max-width: none; padding: 24px clamp(16px, 4vw, 40px) 30vh; }
.code-card { font: 13px/1.6 "SFMono-Regular", ui-monospace, Menlo, monospace; background: var(--block-bg); border-radius: 6px; padding: 8px 0 12px; }
/* Copying from the card copies the code alone: WebKit only knows the prefixed user-select. */
.code-lang { font: 12px -apple-system, sans-serif; color: var(--muted); padding: 2px 16px 8px; -webkit-user-select: none; }
.code-line { display: flex; min-height: 1.6em; }
.code-line .ln { flex: none; width: 3.5em; padding-right: 1.2em; text-align: right; color: var(--muted); opacity: .7; -webkit-user-select: none; }
.code-line .src { flex: 1; min-width: 0; padding-right: 16px; white-space: pre-wrap; overflow-wrap: anywhere; tab-size: 4; }
/* A line number turns into "+" under the pointer; clicking it opens a comment box above the line. */
.commentable .ln { cursor: pointer; }
.commentable .code-line:hover .ln::before { content: "+"; color: var(--accent); font-weight: 700; margin-right: .5em; }
.comment-draft { display: flex; gap: 6px; margin: 0; padding: 3px 16px 3px 4.7em; }
.comment-draft input { flex: 1; font: inherit; color: var(--text); background: var(--bg); border: 1px solid var(--accent);
  border-radius: 4px; padding: 2px 6px; outline: none; }
.comment-draft button { font: 12px -apple-system, sans-serif; color: #fff; background: var(--accent); border: 0;
  border-radius: 4px; padding: 0 10px; }
.code-status { font-size: 14px; margin: 0 0 12px; padding: 7px 12px; border-radius: 6px; }
.code-status.ok { background: rgba(68, 131, 97, .12); color: #448361; }
.code-status.error { background: rgba(235, 87, 87, .12); color: #d44c47; }
.code-status.note { background: rgba(203, 145, 47, .14); color: #b07c1f; }
.data :is(th, td) { white-space: pre-wrap; }
.text-page p { margin: 0; min-height: 1.5em; white-space: pre-wrap; }
""" + TokenKind.css
