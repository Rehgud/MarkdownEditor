import AppKit
import SwiftUI

/// The source editor, on TextKit 2. The text storage stays plain: Markdown lines are styled on
/// their way to the screen (`textParagraphWith`) and code is colored with rendering attributes,
/// so highlighting never touches undo, the document's edited state, or IME composition.
struct Editor: NSViewRepresentable {
    @Binding var text: String
    let format: FileFormat
    let folder: URL?
    let sync: ScrollSync

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = coordinator
        if format.isMarkdown { textView.textContentStorage?.delegate = coordinator }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false // no spaces slipped in around pasted words
        textView.backgroundColor = MarkdownHighlighter.background
        textView.typingAttributes = format.isMarkdown ? MarkdownHighlighter.baseAttributes : CodeTheme.attributes
        textView.textLayoutManager?.renderingAttributesValidator = { [weak coordinator] layout, fragment in
            nonisolated(unsafe) let layout = layout, fragment = fragment
            MainActor.assumeIsolated { coordinator?.color(fragment, in: layout) }
        }
        coordinator.textView = textView
        coordinator.slashMenu.textView = textView
        coordinator.slashMenu.folder = folder
        textView.string = text

        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        coordinator.textChanged()
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.didResize),
                                               name: NSView.frameDidChangeNotification, object: textView)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.storageDidProcessEditing(_:)),
                                               name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
        sync.editor = coordinator
        if sync.findWhenEditorOpens {
            sync.findWhenEditorOpens = false
            DispatchQueue.main.async { coordinator.find() } // once the view is in its window
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.slashMenu.folder = folder
        guard let textView = coordinator.textView, textView.string != text else { return }
        textView.undoManager?.removeAllActions() // their ranges point into the text being replaced
        textView.string = text
        coordinator.textChanged()
    }

    /// Typing undo lives on the document's undo manager (that's what marks it edited and autosaves),
    /// so a mode switch must take this text view's actions with it, or ⌘Z would act on a dead view.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.undoManager?.removeAllActions()
        coordinator.slashMenu.tearDown()
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, format: format, sync: sync) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextContentStorageDelegate {
        var text: Binding<String>
        let format: FileFormat
        let language: CodeLanguage?
        let sync: ScrollSync
        /// Captured while attached, since the view has no window (so no undo manager) at dismantle.
        weak var undoManager: UndoManager?
        weak var textView: NSTextView?
        let slashMenu = SlashMenu()
        private var lineStarts = [0]
        private var codeBlocks: [MarkdownHighlighter.FencedBlock] = []
        private var codeBlocksStale = true
        /// What `color(_:in:)` paints: the whole file for code, fenced blocks with a known language for Markdown.
        private var tokens: [SyntaxToken] = []

        init(text: Binding<String>, format: FileFormat, sync: ScrollSync) {
            self.text = text
            self.format = format
            self.language = format.language.flatMap(CodeLanguage.named)
            self.sync = sync
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            codeBlocksStale = true
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            undoManager = textView.undoManager
            text.wrappedValue = textView.string
            textChanged()
            if format.isMarkdown { slashMenu.update() }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if format.isMarkdown { slashMenu.update() }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if format.isMarkdown { return slashMenu.handle(selector) }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                return newlineKeepingIndent(in: textView)
            // Tab and Shift-Tab indent code the way the file does (no stray tab in YAML or Python);
            // selected lines move as a block, as in VS Code.
            case #selector(NSResponder.insertTab(_:)) where language != nil:
                return indent(in: textView, outward: false)
            case #selector(NSResponder.insertBacktab(_:)) where language != nil:
                return indent(in: textView, outward: true)
            default:
                return false
            }
        }

        /// As in VS Code: selected lines (or one whole line) move as a block and stay selected, without
        /// their last line break; Shift-Tab at a caret moves its line and keeps the caret on its text;
        /// Tab at a caret or in part of a line types the unit.
        private func indent(in textView: NSTextView, outward: Bool) -> Bool {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            let unit = indentUnit(in: source)
            let lines = source.lineRange(for: selection)
            var end = NSMaxRange(lines)
            while end > lines.location, [0x0A, 0x0D].contains(source.character(at: end - 1)) { end -= 1 }
            let wholeLines = selection.length > 0 && selection.location == lines.location && NSMaxRange(selection) >= end
            guard outward || wholeLines || source.substring(with: selection).contains("\n") else {
                textView.insertText(unit, replacementRange: selection)
                return true
            }
            let block = NSRange(location: lines.location, length: end - lines.location)
            let original = source.substring(with: block)
            let shifted = original.components(separatedBy: "\n").map { line in
                if line.allSatisfy(\.isNewline) { return line } // blank lines stay blank
                if !outward { return unit + line }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(min(line.prefix { $0 == " " }.count, unit == "\t" ? 4 : unit.count)))
            }.joined(separator: "\n")
            guard shifted != original else { return true } // nothing to move: no edit, no undo step
            textView.insertText(shifted, replacementRange: block)
            let length = (shifted as NSString).length
            textView.setSelectedRange(selection.length == 0
                ? NSRange(location: max(lines.location, selection.location - (block.length - length)), length: 0)
                : NSRange(location: block.location, length: length))
            return true
        }

        /// VS Code's Return: keep the line's indentation, indent once more after an opener in code, and
        /// give a closer right after the caret its own line (`{|}` becomes a block, caret inside).
        private func newlineKeepingIndent(in textView: NSTextView) -> Bool {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            let lineStart = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let head = source.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
            let indent = String(head.prefix { $0 == " " || $0 == "\t" })
            // Only code opens blocks: a `(` ending a line of a .txt is just a bracket.
            let opener = language == nil ? nil : head.last { !$0.isWhitespace }
            let opens = opener.map { "{[(".contains($0) || ($0 == ":" && language?.indentsAfterColon == true) } ?? false
            let after = NSMaxRange(selection) < source.length ? source.substring(with: NSRange(location: NSMaxRange(selection), length: 1)) : ""
            let closer = opener.flatMap { ["{": "}", "[": "]", "(": ")"][$0] }
            // CRLF files (Excel's CSV, Windows sources) keep CRLF.
            let newline = source.range(of: "\r\n").location == NSNotFound ? "\n" : "\r\n"
            let inner = newline + indent + (opens ? indentUnit(in: source) : "")
            textView.insertText(inner + (opens && closer == after ? newline + indent : ""), replacementRange: selection)
            textView.setSelectedRange(NSRange(location: selection.location + inner.utf16.count, length: 0))
            return true
        }

        private static let indentation = try! NSRegularExpression(pattern: "^(\\t| {2,})(?=\\S)", options: .anchorsMatchLines)

        /// The file's own indent, by majority so a string or docstring can't sway it: tabs if more
        /// lines start with one, else four spaces if nearly all space indents are multiples of four,
        /// else two. Single spaces are alignment (` * ` in doc comments). A file not indented yet gets
        /// the language's habit.
        private func indentUnit(in source: NSString) -> String {
            var tabs = 0, widths: [Int] = []
            for match in Self.indentation.matches(in: source as String, range: NSRange(location: 0, length: min(source.length, 50_000))) {
                if source.character(at: match.range.location) == 0x09 { tabs += 1 } else { widths.append(match.range.length) }
            }
            if tabs > widths.count { return "\t" }
            if !widths.isEmpty {
                let fours = widths.filter { $0 % 4 == 0 }.count
                return fours * 5 >= widths.count * 4 ? "    " : "  "
            }
            return switch format.language {
            case "go": "\t"
            case "yaml", "json": "  "
            default: "    "
            }
        }

        /// One Markdown line, styled for display. Lines below a fence typed above existing text keep
        /// their old look until they're next edited or the document reopens.
        /// ponytail: per-line regeneration; force a full re-layout if that ever matters in practice.
        nonisolated func textContentStorage(_ textContentStorage: NSTextContentStorage,
                                            textParagraphWith range: NSRange) -> NSTextParagraph? {
            nonisolated(unsafe) let contentStorage = textContentStorage
            nonisolated(unsafe) var paragraph: NSTextParagraph?
            MainActor.assumeIsolated {
                guard let storage = contentStorage.textStorage else { return }
                refreshCodeBlocks(in: storage.string as NSString)
                let line = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
                MarkdownHighlighter.style(line, in: codeBlocks.first { NSIntersectionRange($0.range, range).length > 0 })
                paragraph = NSTextParagraph(attributedString: line)
            }
            return paragraph
        }

        private func refreshCodeBlocks(in source: NSString) {
            guard codeBlocksStale else { return }
            codeBlocks = MarkdownHighlighter.fencedCodeBlocks(in: source)
            codeBlocksStale = false
        }

        /// Counts edits to the text storage, and the last one `textChanged` caught up with.
        private var storageVersion = 0, seenVersion = 0

        /// Undo and redo change the text storage without telling the text view's delegate, so colors,
        /// line starts and the document would lag until the next keystroke: catch up once the edit is done.
        @objc func storageDidProcessEditing(_ notification: Notification) {
            guard let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            storageVersion += 1
            DispatchQueue.main.async { [weak self] in
                guard let self, seenVersion != storageVersion, let textView else { return }
                if text.wrappedValue != textView.string { text.wrappedValue = textView.string }
                textChanged()
            }
        }

        func textChanged() {
            guard let textView else { return }
            seenVersion = storageVersion
            let source = textView.string as NSString
            lineStarts = [0]
            var index = 0
            while index < source.length {
                index = NSMaxRange(source.lineRange(for: NSRange(location: index, length: 0)))
                lineStarts.append(index)
            }
            codeBlocksStale = true
            measuredThrough = 0
            recolor(source)
        }

        private func recolor(_ source: NSString) {
            if let language {
                tokens = tokenize(source as String, as: language)
            } else if format.isMarkdown {
                refreshCodeBlocks(in: source)
                tokens = codeBlocks.flatMap { block -> [SyntaxToken] in
                    guard let language = block.language.flatMap(CodeLanguage.named) else { return [] }
                    return tokenize(source.substring(with: block.content), as: language).map {
                        SyntaxToken(range: NSRange(location: $0.range.location + block.content.location, length: $0.range.length), kind: $0.kind)
                    }
                }
            } else {
                return
            }
            guard let layout = textView?.textLayoutManager else { return }
            painted.removeAll()
            layout.invalidateRenderingAttributes(for: layout.documentRange)
            colorViewport()
            // Once the edit is laid out: a long paste can bring lines on screen the old viewport missed.
            DispatchQueue.main.async { [weak self] in self?.colorViewport() }
        }

        /// Lines painted since `tokens` last changed, so scrolling repaints only lines new to the screen.
        private var painted = Set<ObjectIdentifier>()

        /// Paints the lines on screen not painted yet. TextKit 2 runs the validator only for lines it
        /// lays out anew, so after an edit the untouched lines (cleared above) would otherwise draw
        /// uncolored, and stay that way when scrolled back to.
        private func colorViewport() {
            guard language != nil || format.isMarkdown, let textView, let layout = textView.textLayoutManager,
                  let viewport = layout.textViewportLayoutController.viewportRange else { return }
            var changed = false
            layout.enumerateTextLayoutFragments(from: viewport.location) { fragment in
                if !painted.contains(ObjectIdentifier(fragment)) {
                    color(fragment, in: layout)
                    changed = true
                }
                return fragment.rangeInElement.endLocation.compare(viewport.endLocation) == .orderedAscending
            }
            if changed { textView.needsDisplay = true }
        }

        /// Paints `tokens` onto one laid-out line: from the validator for lines TextKit lays out, and
        /// from `colorViewport` for lines it only kept.
        func color(_ fragment: NSTextLayoutFragment, in layout: NSTextLayoutManager) {
            painted.insert(ObjectIdentifier(fragment))
            guard let content = layout.textContentManager else { return }
            let documentStart = content.documentRange.location
            let range = fragment.rangeInElement
            let start = content.offset(from: documentStart, to: range.location)
            let end = content.offset(from: documentStart, to: range.endLocation)
            layout.removeRenderingAttribute(.foregroundColor, for: range)
            var low = 0, high = tokens.count
            while low < high {
                let mid = (low + high) / 2
                if NSMaxRange(tokens[mid].range) <= start { low = mid + 1 } else { high = mid }
            }
            for token in tokens[low...] {
                guard token.range.location < end else { break }
                let from = max(token.range.location, start), to = min(NSMaxRange(token.range), end)
                guard from < to, let a = content.location(documentStart, offsetBy: from),
                      let b = content.location(a, offsetBy: to - from), let span = NSTextRange(location: a, end: b) else { continue }
                layout.addRenderingAttribute(.foregroundColor, value: CodeTheme.color(for: token.kind), for: span)
            }
        }

        /// Makes the text `new` (a comment written in the preview, or undoing one) as one edit of this
        /// text view, so its undo history stays whole. Only the part between what the two texts share
        /// at the start and end is replaced, widened to whole characters.
        func replaceText(with new: String, actionName: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let old = storage.string as NSString, target = new as NSString
            var prefix = 0
            while prefix < old.length, prefix < target.length, old.character(at: prefix) == target.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < old.length - prefix, suffix < target.length - prefix,
                  old.character(at: old.length - 1 - suffix) == target.character(at: target.length - 1 - suffix) { suffix += 1 }
            guard prefix < old.length - suffix || prefix < target.length - suffix else { return }
            let range = old.rangeOfComposedCharacterSequences(for: NSRange(location: prefix, length: old.length - suffix - prefix))
            let replacement = target.substring(with: NSRange(location: range.location,
                                                             length: target.length - (old.length - NSMaxRange(range)) - range.location))
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: textView.typingAttributes))
            textView.didChangeText()
            textView.undoManager?.setActionName(actionName)
        }

        /// A Find menu command passed on from the preview (Find Next, Use Selection…), or the find bar.
        func find(_ action: Selector? = nil, sender: Any? = nil) {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            if let action, let sender { NSApp.sendAction(action, to: textView, from: sender); return }
            let show = NSMenuItem()
            show.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            textView.performFindPanelAction(show)
        }

        @objc func didScroll() {
            colorViewport()
            sync.scrolled(.editor, toLine: topLine())
            if format.isMarkdown { slashMenu.update() }
        }

        /// Markdown reads in a centered column like the preview; code uses the full width.
        @objc func didResize() {
            guard let textView else { return }
            let inset = format.isMarkdown
                ? NSSize(width: max(28, (textView.frame.width - 720) / 2), height: 32)
                : NSSize(width: 8, height: 12)
            if textView.textContainerInset != inset { textView.textContainerInset = inset }
        }

        /// The fractional source line at the top of the viewport. Each TextKit 2 layout fragment
        /// is one source line, so the fraction is how far into that fragment the top edge sits.
        func topLine() -> Double {
            guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else { return 0 }
            // visibleRect, not the clip view's bounds: the two coordinate spaces can be offset.
            let y = textView.visibleRect.minY - textView.textContainerOrigin.y
            guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y))) else { return 0 }
            let frame = fragment.layoutFragmentFrame
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let fraction = frame.height > 0 ? min(max((y - frame.minY) / frame.height, 0), 1) : 0
            return Double(lineIndex(containing: offset)) + fraction
        }

        /// How far the text is laid out for real (not estimated) since it last changed.
        private var measuredThrough = 0

        func scroll(toLine line: Double) {
            guard let textView, line.isFinite, let layout = textView.textLayoutManager,
                  let content = layout.textContentManager else { return }
            // Clamped as a Double: a Markdown file's raw HTML can claim line 1e23, which no Int holds.
            let line = min(max(line, 0), Double(lineStarts.count - 1))
            let index = Int(line)
            let start = content.documentRange.location
            // Measure, don't estimate: TextKit 2 otherwise guesses heights for lines off screen, and
            // sizes the view from those guesses, which cuts scrolling short near the end. Only up to
            // the target, and once per text: a whole large file per scroll event froze the app.
            let through = lineStarts[min(index + 1, lineStarts.count - 1)]
            if through > measuredThrough, let end = content.location(start, offsetBy: through),
               let range = NSTextRange(location: start, end: end) {
                layout.ensureLayout(for: range)
                textView.sizeToFit()
                measuredThrough = through
            }
            // Past the last line (the preview's bottom) there's no fragment: go to the end.
            guard let location = content.location(start, offsetBy: lineStarts[index]),
                  let fragment = layout.textLayoutFragment(for: location) else { return textView.scrollToEndOfDocument(nil) }
            let frame = fragment.layoutFragmentFrame
            textView.scroll(NSPoint(x: 0, y: frame.minY + frame.height * (line - Double(index)) + textView.textContainerOrigin.y))
        }

        func lineIndex(containing char: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= char { low = mid } else { high = mid - 1 }
            }
            return low
        }
    }
}
