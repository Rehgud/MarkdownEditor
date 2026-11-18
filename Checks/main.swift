import Foundation

// Tokenizer checks, run from the project folder:
//   swiftc Shared/Syntax.swift Checks/main.swift -o /tmp/syntax-check && /tmp/syntax-check

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
check("cat <<EOF\nit's here\nEOF\nexit 1", "sh", ["string 's here", "keyword exit", "number 1"])
// Rust: `'"'` is a character, `'a` a lifetime.
check("let c = '\"'; let x = 1;", "rust", ["keyword let", "string '\"'", "keyword let", "number 1"])
check("fn f<'a>(x: &'a str)", "rust", ["keyword fn", "type str"])
// Members aren't keywords; numbers stop where they should.
check("m.get(k); x.default; const n = 1", "js", ["function get", "keyword const", "number 1"])
check("1.max(2) + 0x1E-1 + 1_000 + 2.5e-3", "rust", ["number 1", "function max", "number 2", "number 0x1E", "number 1", "number 1_000", "number 2.5e-3"])
check("int x = 1'000;", "cpp", ["type int", "number 1'000"])
// Markup: tag names are ASCII.
check("<p>a <한글> b</p>", "html", ["tag p", "tag p"])
// YAML and SCSS comments need a space before them; URLs stay intact.
check("url: http://x/#frag # note", "yaml", ["property url", "comment # note"])
check("a { color: red; } // don't", "scss", ["comment // don't"])
check("background: url(http://x.com/a.png)", "scss", ["property background", "function url"])
// Raw strings: Go backticks, SQL quotes.
check("s := `C:\\`; x := 1", "go", ["string `C:\\`", "number 1"])
check("SELECT 'C:\\' FROM t -- x", "sql", ["keyword SELECT", "string 'C:\\'", "keyword FROM", "comment -- x"])
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
]
for (got, want) in comments where got != want { failures += 1; print("✗ comment: \(got.debugDescription)") }

let escaped = escapeHTML("<a href=\"x\">&</a>")
if escaped != "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;" { failures += 1; print("✗ escapeHTML: \(escaped)") }
let line = highlightedLines("let a = \"🦀\" // 한글", language: .named("swift"))
let expectedLine = "<span class=\"tk-keyword\">let</span> a = <span class=\"tk-string\">&quot;🦀&quot;</span> <span class=\"tk-comment\">// 한글</span>"
if line != [expectedLine] { failures += 1; print("✗ highlightedLines: \(line)") }

print(failures == 0 ? "All tokenizer checks passed." : "\(failures) tokenizer check(s) failed.")
exit(failures == 0 ? 0 : 1)
