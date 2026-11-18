import SwiftUI
import UniformTypeIdentifiers

@main
struct MarkdownEditorApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        DocumentGroup(newDocument: TextDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
        }
        .commands {
            TextEditingCommands() // 찾기 (⌘F), spelling, substitutions
            ViewModeCommands()
            NewFileCommands()
        }
    }
}

struct TextDocument: FileDocument {
    /// Markdown first, so ⌘N documents save as .md. `.data` lets a file of any name open as text,
    /// including extensions macOS doesn't know (.go, .rs) or files as something else (.ts is video
    /// to it); a file that isn't text is refused below instead.
    static let readableContentTypes: [UTType] = [.markdown, .plainText, .text, .data]
    /// Korean Windows' encoding (EUC-KR and more): Excel's CSV and many public-data downloads.
    private static let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
    /// Byte-order marks and the encodings they announce: UTF-8 (Excel's "CSV UTF-8"), and UTF-16, which
    /// Windows calls "Unicode" (desktop.ini, Notepad).
    private static let marks: [(bom: Data, encoding: String.Encoding)] = [
        (Data([0xEF, 0xBB, 0xBF]), .utf8), (Data([0xFF, 0xFE]), .utf16LittleEndian), (Data([0xFE, 0xFF]), .utf16BigEndian),
    ]
    var text = ""
    /// Saved back the way it came: its encoding and byte-order mark.
    private var encoding = String.Encoding.utf8
    private var bom = Data()

    init() {}

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        if !data.starts(with: [0xFF, 0xFE, 0, 0]), // UTF-32, which shares UTF-16's first bytes
           let mark = Self.marks.first(where: { data.starts(with: $0.bom) }),
           let text = String(data: data.dropFirst(mark.bom.count), encoding: mark.encoding) {
            (self.text, encoding, bom) = (text, mark.encoding, mark.bom)
        } else if let text = String(data: data, encoding: .utf8) {
            self.text = text
        } else if let text = String(data: data, encoding: Self.cp949), text.data(using: Self.cp949) == data {
            // Only CP949 that saves back byte for byte: its user-defined rows decode but don't encode.
            (self.text, encoding) = (text, Self.cp949)
        } else {
            // Refuse the rest rather than decode lossily and overwrite the original on save.
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let data = text.data(using: encoding) { return FileWrapper(regularFileWithContents: bom + data) }
        // CP949 text that gained a character CP949 lacks (emoji): UTF-8 keeps it, its BOM keeps Excel reading it.
        return FileWrapper(regularFileWithContents: Self.marks[0].bom + Data(text.utf8))
    }
}

enum ViewMode: CaseIterable, Identifiable {
    case editor, split, preview

    var id: Self { self }

    var title: String {
        switch self {
        case .editor: String(localized: "편집")
        case .split: String(localized: "분할")
        case .preview: String(localized: "미리보기")
        }
    }

    var symbol: String {
        switch self {
        case .editor: "pencil"
        case .split: "rectangle.split.2x1"
        case .preview: "eye"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .editor: "1"
        case .split: "2"
        case .preview: "3"
        }
    }
}

extension FileFormat {
    /// Files open ready to read, on the preview. A new one (empty, or just its template) opens ready to
    /// write: beside its preview, or alone where the preview would only repeat the code.
    func initialMode(for text: String) -> ViewMode {
        guard text.isEmpty || text == template else { return .preview }
        return preview == .code || preview == .text ? .editor : .split
    }

    /// New files' name: 제목 없음 for documents; code gets one that imports and compilers accept.
    var untitledName: String { preview == .code ? "untitled" : String(localized: "제목 없음") }
}

struct ContentView: View {
    @Binding var document: TextDocument
    let fileURL: URL?
    /// The format the user picked for files like this one (by extension); empty means the default.
    @AppStorage private var declared: String
    @State private var mode: ViewMode
    /// The editor's share of the window in split view.
    @State private var split = 0.5
    @State private var sync = ScrollSync()
    @Environment(\.undoManager) private var undoManager

    init(document: Binding<TextDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        _declared = AppStorage(wrappedValue: "", fileURL.map(FileFormat.declarationKey(for:)) ?? "format.untitled")
        _mode = State(initialValue: FileFormat(url: fileURL).initialMode(for: document.wrappedValue.text))
    }

    private var format: FileFormat { FileFormat(url: fileURL, declared: declared) }
    private var folder: URL? { fileURL?.deletingLastPathComponent() }

    var body: some View {
        let format = format
        // Each side stays put through mode switches, so the editor keeps its undo history and the
        // preview its scroll position. (HSplitView misjudged a side's width when it came back.)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if mode != .preview {
                    Editor(text: $document.text, format: format, folder: folder, sync: sync).id(format)
                        .frame(width: mode == .split ? editorWidth(in: geometry.size.width) : nil)
                }
                if mode == .split {
                    SplitDivider(share: $split, total: geometry.size.width)
                }
                if mode != .editor {
                    Preview(text: document.text, format: format, folder: folder, sync: sync, find: openFind, comment: addComment)
                        .id(format)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .toolbar {
            if let fileURL {
                if format.preview == .page {
                    ToolbarItem {
                        Button("브라우저에서 열기", systemImage: "safari") { openInBrowser(fileURL) }
                            .help("브라우저에서 열기 · 미리보기는 스크립트를 실행하지 않아요")
                    }
                }
                ToolbarItem {
                    FormatMenu(format: format, fileURL: fileURL, declared: $declared)
                }
            }
            ToolbarItem {
                Picker("보기", selection: $mode) {
                    ForEach(ViewMode.allCases) { Label($0.title, systemImage: $0.symbol) }
                }
                .pickerStyle(.segmented)
            }
        }
        .focusedSceneValue(\.viewMode, $mode)
    }

    /// Both sides keep at least 240pt.
    private func editorWidth(in total: CGFloat) -> CGFloat {
        max(240, min(total * split, total - 240 - SplitDivider.width))
    }

    /// The default browser, not the default app for .html (which could be this one), after saving.
    private func openInBrowser(_ file: URL) {
        NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
        guard let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://")!) else { return }
        NSWorkspace.shared.open([file], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A comment written on the preview's line numbers, put on its own line above that line in the
    /// language's syntax: through the editor when it's open (its undo), otherwise straight into the
    /// document, as one undoable step.
    private func addComment(line: Int, text: String) {
        guard let id = format.language, let comment = commentLine(text, language: id) else { return }
        let insertion = commentInsertion(comment, aboveLine: line, in: document.text, language: id)
        let edited = (document.text as NSString).replacingCharacters(in: NSRange(location: insertion.location, length: 0),
                                                                     with: insertion.text)
        Self.setText(edited, of: $document, sync: sync, undo: undoManager, actionName: String(localized: "주석 추가"))
    }

    /// Sets the whole text as one step ⌘Z takes back (and ⇧⌘Z redoes). With the editor open the change
    /// goes through it, so its own undo records it; replacing its text from outside would cost it its
    /// whole history.
    private static func setText(_ text: String, of document: Binding<TextDocument>, sync: ScrollSync,
                                undo: UndoManager?, actionName: String) {
        if let editor = sync.editor { return editor.replaceText(with: text, actionName: actionName) }
        let old = document.wrappedValue.text
        document.wrappedValue.text = text
        guard let undo else { return }
        undo.registerUndo(withTarget: undo) { undo in
            MainActor.assumeIsolated { setText(old, of: document, sync: sync, undo: undo, actionName: actionName) }
        }
        undo.setActionName(actionName)
    }

    /// Find from the preview: search in the editor, opening it beside the preview if it's hidden.
    /// The preview follows the found line through scroll sync.
    private func openFind(_ action: Selector, _ sender: Any?) {
        if mode == .preview {
            sync.findWhenEditorOpens = true
            mode = .split
        } else {
            sync.editor?.find(action, sender: sender)
        }
    }
}

/// The split view's divider: a hairline with a wider grip. Dragging sets the editor's share; a
/// double click evens it out.
private struct SplitDivider: View {
    static let width: CGFloat = 7
    @Binding var share: Double
    let total: CGFloat
    @State private var dragStart: Double?

    var body: some View {
        Rectangle().fill(.separator).frame(width: 1)
            .frame(width: Self.width).frame(maxHeight: .infinity)
            .background(Color(nsColor: MarkdownHighlighter.background))
            .contentShape(.rect)
            .pointerStyle(.columnResize)
            .onTapGesture(count: 2) { share = 0.5 }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? share
                    dragStart = start
                    // The same stops editorWidth draws at, so pulling back moves the divider at once.
                    let low = 240 / total, high = max(low, (total - 240 - Self.width) / total)
                    share = min(max(start + drag.translation.width / total, low), high)
                }
                .onEnded { _ in dragStart = nil })
    }
}

/// Declares what files like this one are, VS Code's "language mode": the choice applies to every
/// file with the same extension, and the default menu item clears it.
struct FormatMenu: View {
    let format: FileFormat
    let fileURL: URL
    @Binding var declared: String

    var body: some View {
        Menu {
            // The choice covers every file of this kind, so the menu names the kind.
            Section("모든 \(fileURL.pathExtension.isEmpty ? fileURL.lastPathComponent : "." + fileURL.pathExtension) 파일의 형식") {
                ForEach(FileFormat.common) { option(for: $0) }
                Menu("더 보기") {
                    ForEach(FileFormat.all.filter { !FileFormat.common.contains($0) }) { option(for: $0) }
                }
            }
            Divider()
            Button("기본 형식으로 되돌리기 (\(FileFormat(url: fileURL, declared: "").name))") { declared = "" }
                .disabled(declared.isEmpty)
        } label: {
            Text(format.name)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("이 확장자의 파일을 볼 형식 선택")
    }

    private func option(for option: FileFormat) -> some View {
        Toggle(option.name, isOn: Binding(get: { option == format }, set: { _ in declared = option.id }))
    }
}

/// Keeps split-view editor and preview showing the same source line. Whichever side the user
/// scrolls leads for a moment, so the follower's own scroll events don't echo back.
@MainActor
final class ScrollSync {
    enum Side { case editor, preview }

    weak var editor: Editor.Coordinator?
    weak var preview: Preview.Coordinator?
    /// Set by ⌘F in the preview alone: the editor about to appear opens its find bar.
    var findWhenEditorOpens = false
    private var leader = Side.editor
    private var leadUntil = Date.distantPast

    func scrolled(_ side: Side, toLine line: Double) {
        let now = Date()
        guard side == leader || now >= leadUntil else { return }
        leader = side
        leadUntil = now.addingTimeInterval(0.25)
        switch side {
        case .editor: preview?.scroll(toLine: line)
        case .preview: editor?.scroll(toLine: line)
        }
    }

    /// After a re-render the preview's layout shifted; put it back on the editor's line.
    func alignPreview() {
        guard let editor else { return }
        leader = .editor
        leadUntil = Date().addingTimeInterval(0.25)
        preview?.scroll(toLine: editor.topLine())
    }
}

extension FocusedValues {
    @Entry var viewMode: Binding<ViewMode>?
}

struct ViewModeCommands: Commands {
    @FocusedBinding(\.viewMode) private var mode

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(ViewMode.allCases) { item in
                Button(item.title) { mode = item }
                    .keyboardShortcut(item.shortcut)
                    .disabled(mode == nil)
            }
            Divider()
        }
    }
}

struct NewFileCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Menu("새 파일") {
                ForEach(FileFormat.common) { format in
                    Button("\(format.name) (.\(format.fileExtension))") { NewFile.createWithPanel(suggesting: format) }
                }
                Menu("더 보기") {
                    ForEach(FileFormat.more) { format in
                        Button("\(format.name) (.\(format.fileExtension))") { NewFile.createWithPanel(suggesting: format) }
                    }
                }
                Divider()
                Button("이름 직접 입력…") { NewFile.createWithPanel(suggesting: nil) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let key = "askedToBeDefaultMarkdownApp"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .markdown) { _ in }
    }

    /// From the Finder extension: `markdowneditor://new?dir=/path&ext=py` makes a Python file there,
    /// `&ask=1` one of any kind, `&folder=1` a folder. Every time the name prompt shows where and waits
    /// for the user, so no link (from Finder or a web page) creates anything on its own.
    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let components = URLComponents(string: string), components.host == "new",
              let dir = components.queryItems?.first(where: { $0.name == "dir" })?.value, dir.hasPrefix("/"),
              case let folder = URL(filePath: dir, directoryHint: .isDirectory),
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return }
        if components.queryItems?.contains(where: { $0.name == "folder" }) == true {
            if let made = NewFile.createFolder(in: folder) { NSWorkspace.shared.activateFileViewerSelecting([made]) }
            return
        }
        let ask = components.queryItems?.contains { $0.name == "ask" } == true
        let ext = components.queryItems?.first { $0.name == "ext" }?.value ?? "md"
        let format = ask ? nil : FileFormat.all.first { $0.extensions.contains(ext.lowercased()) } ?? .markdown
        if let file = NewFile.create(in: folder, suggesting: format) { NewFile.open(file) }
    }
}

@MainActor
enum NewFile {
    /// Asks for the new file's name, as Windows' 새로 만들기 does: the first free 제목 없음.md
    /// (untitled.py, untitled_2.py, … for code) filled in, with the part before the extension selected.
    /// A name typed without an extension gets the format's. Creates the file holding its template
    /// (never over an existing one) and returns it; nil if cancelled. `format` nil asks for any kind.
    static func create(in folder: URL, suggesting format: FileFormat?) -> URL? {
        NSApp.activate()
        var name = firstFreeName(in: folder, for: format ?? .text)
        var problem = ""
        while true {
            // A format's prompt selects the name before the extension; "any kind" selects all of it,
            // since the extension is the user's to type.
            let selected = format == nil ? name.utf16.count : (name as NSString).deletingPathExtension.utf16.count
            guard let typed = askName(
                title: format.map { String(localized: "새 \($0.name) 파일") } ?? String(localized: "새 파일"),
                note: problem + String(localized: "위치: \(place(folder))")
                    + (format == nil ? "\n" + String(localized: "확장자까지 입력하세요.\n예: main.go, notes.txt, .env") : ""),
                name: name, selecting: selected)
            else { return nil }
            name = typed
            // A format's own extension goes on unless the name already ends in one: "회의록 v1.2" and
            // "2024.11.17" end in numbers, not extensions.
            if let format, !name.isEmpty, !name.hasPrefix("."), !Self.endsInExtension(name) {
                name += "." + format.fileExtension
            }
            // A format's prompt makes visible files: an emptied name leaves just ".md".
            guard isUsable(name), format == nil || !name.hasPrefix(".") else {
                problem = String(localized: "이 이름은 쓸 수 없어요.") + "\n"
                continue
            }
            let url = folder.appending(path: name)
            do {
                try Data(FileFormat(url: url).template.utf8).write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                problem = String(localized: "같은 이름의 파일이 이미 있어요.") + "\n"
            } catch {
                NSAlert(error: error).runModal()
                return nil
            }
        }
    }

    /// Asks for a new folder's name, Finder's 무제 폴더 (무제 폴더 2, …) filled in and selected, and makes
    /// the folder (never over an existing item). Nil if cancelled.
    static func createFolder(in folder: URL) -> URL? {
        NSApp.activate()
        let untitled = String(localized: "무제 폴더")
        var name = untitled, n = 1
        while FileManager.default.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false)) {
            n += 1
            name = "\(untitled) \(n)"
        }
        var problem = ""
        while true {
            guard let typed = askName(title: String(localized: "새 폴더"), note: problem + String(localized: "위치: \(place(folder))"),
                                      name: name, selecting: name.utf16.count)
            else { return nil }
            name = typed
            guard isUsable(name) else {
                problem = String(localized: "이 이름은 쓸 수 없어요.") + "\n"
                continue
            }
            let url = folder.appending(path: name, directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch CocoaError.fileWriteFileExists {
                problem = String(localized: "같은 이름의 항목이 이미 있어요.") + "\n"
            } catch {
                NSAlert(error: error).runModal()
                return nil
            }
        }
    }

    /// The name prompt files and folders share; the typed name, trimmed, or nil if cancelled.
    private static func askName(title: String, note: String, name: String, selecting length: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = note
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = name
        field.usesSingleLineMode = true // a pasted line break becomes a space
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "만들기"))
        alert.addButton(withTitle: String(localized: "취소"))
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async { field.currentEditor()?.selectedRange = NSRange(location: 0, length: length) }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    /// A name the file system and Finder accept as one item in the folder.
    private static func isUsable(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.union(.newlines).contains)
    }

    /// Whether the name ends in an extension the app or macOS knows (not just ".2" of "v1.2").
    private static func endsInExtension(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return FileFormat.all.contains { $0.extensions.contains(ext) } || UTType(filenameExtension: ext)?.isDynamic == false
    }

    /// 제목 없음.md, 제목 없음 2.md, …; untitled.py, untitled_2.py, … for code, which imports and
    /// compilers need a plain name for.
    private static func firstFreeName(in folder: URL, for format: FileFormat) -> String {
        let joiner = format.preview == .code ? "_" : " "
        var n = 1
        while true {
            let name = (n == 1 ? format.untitledName : "\(format.untitledName)\(joiner)\(n)") + "." + format.fileExtension
            if !FileManager.default.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false)) { return name }
            n += 1
        }
    }

    /// File ▸ 새 파일: the user picks the place and name, any extension, then it opens with the
    /// template of whatever format that name turns out to be.
    static func createWithPanel(suggesting format: FileFormat?) {
        let panel = NSSavePanel()
        // "Any kind" suggests no extension: the panel selects only the part before one, and typing
        // main.go over that would make main.go.txt.
        panel.nameFieldStringValue = format.map { $0.untitledName + "." + $0.fileExtension } ?? String(localized: "제목 없음")
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(FileFormat(url: url).template.utf8).write(to: url, options: .atomic)
            open(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func place(_ folder: URL) -> String {
        (folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    static func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }
}
