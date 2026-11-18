import Foundation

// Tokenizer checks, run from the project folder:
//   swiftc Shared/Syntax.swift Shared/Render.swift Shared/FileFormats.swift Shared/TextEncoding.swift Checks/Stubs.swift Checks/main.swift -o /tmp/checks && /tmp/checks

var failures = 0

func check(_ code: String, _ language: String, _ expected: [String], line: Int = #line) {
    let source = code as NSString
    let got = tokenize(code, as: CodeLanguage.named(language)!).map { "\($0.kind) \(source.substring(with: $0.range))" }
    guard got != expected else { return }
    failures += 1
    print("✗ line \(line) \(language): \(code.debugDescription)\n  got      \(got)\n  expected \(expected)")
}

// Shell: `$#` is a variable, `#` mid-word isn't a comment, single quotes keep backslashes.
check("if [ $# -eq 0 ]; then # done", "sh", ["keyword if", "property $#", "number 0", "keyword then", "comment # done"])
check("echo a#b", "sh", [])
check("tr '\\' x; echo \"$HOME\"", "sh", ["string '\\'", "string \"$HOME\""])
// A here-document is one string from the line break before its text, so its apostrophe opens none.
check("cat <<EOF\nit's here\nEOF\nexit 1", "sh", ["string \nit's here\nEOF", "keyword exit", "number 1"])
// `<<` in `(( ))` shifts and `<<<` is a here-string: neither opens a here-document.
check("cat <<-'E' | wc; x=$(( n << m ))\n\tit's\n\tE\necho $((1 << 2)) <<< it\nexit", "sh",
      ["string \n\tit's\n\tE", "number 1", "number 2", "keyword exit"])
// `\'` outside a string opens none; `$'…'` has escapes.
check("awk '\n{ print $1 }\n' f; echo 'it'\\''s' $'it\\'s' it\\'s\nexit", "sh",
      ["string '\n{ print $1 }\n'", "string 'it'", "string 's'", "string 'it\\'s'", "keyword exit"])
// Ruby: `<<~`, `<<-` or a bare upper-case word; `b << c`, `d <<e`, `1<<F` and `class <<self` open none.
check("a = <<~SQL + <<EOS\n  it's\n  SQL\nx\nEOS\nb << c; d <<e; 1<<F\nclass <<self\ns = \"a\nb\"", "ruby",
      ["string \n  it's\n  SQL\nx\nEOS", "number 1", "keyword class", "keyword self", "string \"a\nb\""])
// PHP: the closing word may be indented and followed by code.
check("<?php $a = <<<EOT\nit's $x\n  EOT;\n$b = <<<'E'\nE . 1;", "php",
      ["property $a", "string \nit's $x\n  EOT", "property $b", "string \nE", "number 1"])
// YAML block scalars: the lines indented deeper than the key (or the list item's dash) are text.
check("- run: |- # sh\n    echo it's\n\n    b: 1\n  env: a > b\n- >\n  x\n- y", "yaml",
      ["property run", "comment # sh", "string \n    echo it's\n\n    b: 1", "property env", "string \n  x"])
// Rust: `'"'` is a character, `'a` a lifetime.
check("let c = '\"'; let x = 1;", "rust", ["keyword let", "string '\"'", "keyword let", "number 1"])
check("fn f<'a>(x: &'a str)", "rust", ["keyword fn", "type str"])
// Members aren't keywords; numbers stop where they should.
check("m.get(k); x.default; const n = 1", "js", ["function get", "keyword const", "number 1"])
check("1.max(2) + 0x1E-1 + 1_000 + 2.5e-3", "rust", ["number 1", "function max", "number 2", "number 0x1E", "number 1", "number 1_000", "number 2.5e-3"])
check("int x = 1'000;", "cpp", ["type int", "number 1'000"])
// Raw strings: Rust closes at as many `#`, C++ at the same delimiter; `r#type` is a name.
check("let s = r#\"a \"b\" \\\"#; let t = br\"\\\"; r#type", "rust",
      ["keyword let", "string r#\"a \"b\" \\\"#", "keyword let", "string br\"\\\"", "keyword type"])
check("auto s = u8R\"x(a \"b\" )\" \\)x\"; int n = 1;", "cpp", ["keyword auto", "string u8R\"x(a \"b\" )\" \\)x\"", "type int", "number 1"])
// Markup: tag names are ASCII.
check("<p>a <한글> b</p>", "html", ["tag p", "tag p"])
// YAML and SCSS comments need a space before them; URLs stay intact.
check("url: http://x/#frag # note", "yaml", ["property url", "comment # note"])
check("a { color: red; } // don't", "scss", ["comment // don't"])
check("background: url(http://x.com/a.png)", "scss", ["property background", "function url"])
// Raw strings: Go backticks. SQL follows MySQL dumps instead: \' stays inside the string, since SQL
// strings span lines and one misread quote would swallow the rest of the dump.
check("s := `C:\\`; x := 1", "go", ["string `C:\\`", "number 1"])
check("VALUES ('O\\'Brien', 1);\nSELECT 2", "sql", ["keyword VALUES", "string 'O\\'Brien'", "number 1", "keyword SELECT", "number 2"])
check("SELECT 'a\nb', \"c\nd\" FROM t", "sql", ["keyword SELECT", "string 'a\nb'", "string \"c\nd\"", "keyword FROM"])
check("{\"a\": 1, \"b\": \"x\"}", "json", ["property \"a\"", "number 1", "property \"b\"", "string \"x\""])

// Comments added from the preview: the language's syntax, above the line, indented like it, and
// never inside something it would break.
func insertion(_ text: String, _ line: Int, _ language: String, comment: String = "메모") -> String {
    let (location, inserted) = commentInsertion(commentLine(comment, language: language)!, aboveLine: line, in: text, language: language)
    return (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: inserted)
}
let comments: [(String, String)] = [
    (insertion("def f():\n    return 1\n", 2, "python"), "def f():\n    # 메모\n    return 1\n"),
    (insertion("a {\n\tcolor: red;\n}", 2, "css"), "a {\n\t/* 메모 */\n\tcolor: red;\n}"),
    (insertion("<a/>\r\n<b/>\r\n", 2, "xml"), "<a/>\r\n<!-- 메모 -->\r\n<b/>\r\n"),
    (insertion("x := 1", 1, "go"), "// 메모\nx := 1"),
    // Text that would close the comment early is broken up; line breaks become spaces.
    (insertion("a {}", 1, "css", comment: "fix */ later"), "/* fix * / later */\na {}"),
    (insertion("<a/>", 1, "xml", comment: "use --force\nnow"), "<!-- use - -force now -->\n<a/>"),
    (insertion("int x;", 1, "c", comment: "C:\\"), "// C:\nint x;"),
    // Not between a line and its continuation, nor inside a string, comment or tag.
    (insertion("echo one \\\n  two\n", 2, "shell"), "# 메모\necho one \\\n  two\n"),
    (insertion("s = \"\"\"\nhi\n\"\"\"\n", 2, "python"), "# 메모\ns = \"\"\"\nhi\n\"\"\"\n"),
    (insertion("<a\n  b=\"1\"/>", 2, "xml"), "<!-- 메모 -->\n<a\n  b=\"1\"/>"),
    // Below what the system reads first; a blank line takes the next line's indentation.
    (insertion("#!/bin/zsh\necho hi\n", 1, "shell"), "#!/bin/zsh\n# 메모\necho hi\n"),
    (insertion("<?xml version=\"1.0\"?>\n<a/>", 1, "xml"), "<?xml version=\"1.0\"?>\n<!-- 메모 -->\n<a/>"),
    (insertion("#!/bin/zsh", 1, "shell"), "#!/bin/zsh\n# 메모\n"),
    (insertion("if x:\n\n    y()\n", 2, "python"), "if x:\n    # 메모\n\n    y()\n"),
    // Not in a here-document (an empty one too), a string that spans lines, or a YAML block scalar.
    (insertion("cat > out.txt <<EOF\nline1\nline2\nEOF", 3, "shell"), "# 메모\ncat > out.txt <<EOF\nline1\nline2\nEOF"),
    (insertion("cat <<EOF\nEOF\n", 2, "shell"), "# 메모\ncat <<EOF\nEOF\n"),
    (insertion("cat <<EOF\r\na\r\nEOF\r\necho\r\n", 4, "shell"), "cat <<EOF\r\na\r\nEOF\r\n# 메모\r\necho\r\n"),
    (insertion("awk '\n{ print }\n' f", 2, "shell"), "# 메모\nawk '\n{ print }\n' f"),
    (insertion("s = 'a\nb'", 2, "ruby"), "# 메모\ns = 'a\nb'"),
    (insertion("SELECT 'a\nb';", 2, "sql"), "-- 메모\nSELECT 'a\nb';"),
    (insertion("let s = r#\"\na\"b\n\"#;", 3, "rust"), "// 메모\nlet s = r#\"\na\"b\n\"#;"),
    (insertion("auto s = R\"(\na\nb)\";", 2, "cpp"), "// 메모\nauto s = R\"(\na\nb)\";"),
    (insertion("msg: |\n  hello\n  world", 3, "yaml"), "# 메모\nmsg: |\n  hello\n  world"),
    // `?>` would end PHP mode; a `>` in an attribute value doesn't end its tag.
    (insertion("<?php\n$x = 1;", 2, "php", comment: "see ?> tag"), "<?php\n// see ? > tag\n$x = 1;"),
    (insertion("<xsl:if test=\"count(x) > 1\"\n        name=\"y\">", 2, "xml"), "<!-- 메모 -->\n<xsl:if test=\"count(x) > 1\"\n        name=\"y\">"),
    // A CRLF file that is all first line gets one line break, not two.
    (insertion("#!/bin/sh\r\n", 1, "shell"), "#!/bin/sh\r\n# 메모\r\n"),
    (insertion("#!/usr/bin/python\r\n# coding: utf-8", 1, "python"), "#!/usr/bin/python\r\n# coding: utf-8\r\n# 메모\r\n"),
    // JSX children take `{/* */}`; a generic's `>` is no tag.
    (insertion("return (\n  <div>\n    Hello\n  </div>\n);", 3, "javascript"), "return (\n  <div>\n    {/* 메모 */}\n    Hello\n  </div>\n);"),
    (insertion("return (\n  <div>\n  </div>\n);", 3, "typescript", comment: "a */ b"), "return (\n  <div>\n  {/* a * / b */}\n  </div>\n);"),
    (insertion("let x: Array<number>\n  = []", 2, "typescript"), "let x: Array<number>\n  // 메모\n  = []"),
]
for (got, want) in comments where got != want { failures += 1; print("✗ comment: \(got.debugDescription)") }

// Only where JSX children go: not in plain code, a callback inside `{ }` or a tag still open.
let jsx = "const a = (\n  <ul>\n    {items.map(i => (\n      <li>{i}</li>\n    ))}\n    <li\n      key=\"x\"\n    >\n      {last}\n    </li>\n  </ul>\n);"
let jsxChildren = (1...12).filter { insertion(jsx, $0, "javascript").contains("{/* 메모 */}") }
if jsxChildren != [3, 6, 9, 10, 11] { failures += 1; print("✗ JSX comment lines: \(jsxChildren)") }

let escaped = escapeHTML("<a href=\"x\">&</a>")
if escaped != "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;" { failures += 1; print("✗ escapeHTML: \(escaped)") }
let line = highlightedLines("let a = \"🦀\" // 한글", language: .named("swift"))
let expectedLine = "<span class=\"tk-keyword\">let</span> a = <span class=\"tk-string\">&quot;🦀&quot;</span> <span class=\"tk-comment\">// 한글</span>"
if line != [expectedLine] { failures += 1; print("✗ highlightedLines: \(line)") }

// CSV: quoted line breaks and blank lines keep row numbers; VT and FF aren't line breaks.
let csv = parseDelimited("a,b\n\"x\r\ny\",\"q\"\"\"\n\nlast", separator: ",")
if csv.map(\.line) != [1, 2, 5] || csv.map(\.fields) != [["a", "b"], ["x\r\ny", "q\""], ["last"]] { failures += 1; print("✗ parseDelimited: \(csv)") }
let vt = parseDelimited("a\u{0B}b\nc\u{0C}d\n\"x\u{0B}y\"\nz", separator: ",")
if vt.map(\.line) != [1, 2, 3, 4] || vt.map(\.fields) != [["a\u{0B}b"], ["c\u{0C}d"], ["x\u{0B}y"], ["z"]] { failures += 1; print("✗ parseDelimited VT/FF: \(vt)") }
// JSON status: ok, note (trailing comma, JSON5), error.
let jsonCases: [(String, String)] = [
    ("{\"a\": 1}", "ok"), ("{\"a\": 1,}", "note"), ("[1,2,]", "note"), ("{a: 'x'}", "note"), ("{\"a\": }", "error"),
    ("{\"a\": \"x,}\"}", "ok"), ("[1, // c\n]", "note"),
]
for (text, want) in jsonCases {
    guard case .body(let html, _) = renderPreview(text, as: FileFormat(url: URL(fileURLWithPath: "a.json"), declared: "json")), html.contains("code-status \(want)") else {
        failures += 1; print("✗ json status \(text.debugDescription) expected \(want)"); continue
    }
}
// Text files open in the encoding they came in and save back byte for byte, as TextDocument saves.
let encoded: [(String, Data, String.Encoding)] = [
    ("UTF-8", Data("# 제목\n".utf8), .utf8),
    ("UTF-8 BOM", byteOrderMarks[0].bom + Data("# 제목\n".utf8), .utf8),
    ("UTF-16LE", byteOrderMarks[1].bom + "# 제목\n".data(using: .utf16LittleEndian)!, .utf16LittleEndian),
    ("UTF-16BE", byteOrderMarks[2].bom + "# 제목\n".data(using: .utf16BigEndian)!, .utf16BigEndian),
    ("CP949", "# 제목\n".data(using: cp949)!, cp949),
]
for (name, data, encoding) in encoded {
    guard let decoded = decodeText(data), decoded.text == "# 제목\n", decoded.encoding == encoding,
          decoded.bom + decoded.text.data(using: decoded.encoding)! == data
    else { failures += 1; print("✗ decodeText \(name): \(String(describing: decodeText(data)))"); continue }
}
// Ones that would lose a byte on save: an odd-length UTF-16 file, a second UTF-8 mark (decoding drops it).
for data in [Data([0xFF, 0xFE, 0x41, 0x00, 0x42]), Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x41])] where decodeText(data) != nil {
    failures += 1; print("✗ decodeText should refuse \(Array(data))")
}

print(failures == 0 ? "All tokenizer checks passed." : "\(failures) tokenizer check(s) failed.")
exit(failures == 0 ? 0 : 1)
