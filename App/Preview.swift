import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct Preview: NSViewRepresentable {
    let text: String
    let format: FileFormat
    let folder: URL?
    let sync: ScrollSync
    /// A Find menu command here (its action and sender): a web view has no find bar, so the editor's
    /// takes it instead.
    let find: @MainActor (Selector, Any?) -> Void
    /// A comment written on a code card's line number: (line, text).
    let comment: @MainActor (Int, String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(LocalAssets(), forURLScheme: LocalAssets.scheme)
        let scripts = configuration.userContentController
        scripts.add(context.coordinator, contentWorld: .defaultClient, name: "previewScroll")
        scripts.add(context.coordinator, contentWorld: .defaultClient, name: "previewComment")
        scripts.addUserScript(WKUserScript(source: Self.scrollScript, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: .defaultClient))
        let webView = FindingWebView(frame: .zero, configuration: configuration)
        webView.find = find
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        sync.preview = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.comment = comment
        // Only a code card takes comments; a page or Markdown file could otherwise fake one.
        coordinator.commentable = format.preview == .code && format.language.flatMap { commentLine("", language: $0) } != nil
        // A divider drag or mode switch updates the view with nothing new to show; rendering a large
        // file again each time made the divider lag.
        guard coordinator.rendered?.text != text || coordinator.rendered?.format != format
                || coordinator.rendered?.folder != folder else { return }
        coordinator.rendered = (text, format, folder)
        coordinator.show(renderPreview(text, as: format), folder: folder)
    }

    func makeCoordinator() -> Coordinator { Coordinator(sync: sync) }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let sync: ScrollSync
        weak var webView: WKWebView?
        var comment: (@MainActor (Int, String) -> Void)?
        var commentable = false
        var rendered: (text: String, format: FileFormat, folder: URL?)?
        private var content: PreviewContent?
        private var folder: URL?
        private var loaded = false
        /// The web view holds the user's own HTML page rather than the app's styled one.
        private var showingPage = false

        init(sync: ScrollSync) { self.sync = sync }

        /// Styled content swaps into the body in place, so typing doesn't reload or reset scroll.
        /// An HTML file replaces the document's contents the same way once it's loaded.
        func show(_ content: PreviewContent, folder: URL?) {
            guard content != self.content || folder != self.folder else { return }
            (webView as? FindingWebView)?.forgetTyping() // the update replaces any open comment box
            let firstShow = self.content == nil
            self.content = content
            self.folder = folder
            switch content {
            case .page(let html):
                if showingPage, loaded {
                    run("document.documentElement.innerHTML = \(jsLiteral(Self.documentContents(html)))")
                } else {
                    load(Self.withPolicy(html), page: true)
                }
            case .body:
                if firstShow || showingPage { load(previewHTML(), page: false) } else if loaded { push() }
            }
        }

        private func load(_ html: String, page: Bool) {
            loaded = false
            showingPage = page
            // A page without a background of its own is drawn on white, as a browser would; the
            // app's page paints its own, light or dark.
            webView?.setValue(page, forKey: "drawsBackground")
            webView?.loadHTMLString(html, baseURL: folder.flatMap(LocalAssets.url(for:)) ?? URL(string: "\(LocalAssets.scheme):///"))
        }

        /// The page with the preview's policy in front (after a leading doctype, so the page keeps its
        /// rendering mode; one behind a comment or `<?xml?>` ends up in quirks mode): no scripts, frames
        /// or plug-ins; images, styles and fonts load as in a browser, audio and video from the web
        /// only. Once read, the policy holds through later in-place updates.
        private static func withPolicy(_ html: String) -> String {
            let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
                + "img-src md-local: data: https: http:; style-src md-local: 'unsafe-inline' https: http:; "
                + "font-src md-local: data: https: http:; media-src data: https: http:\">"
            // HTML's own whitespace only: a no-break space before the doctype is text to the parser, which
            // would put the policy in the body, where it does nothing.
            let doctype = html.range(of: "^[\\t\\n\\f\\r ]*<!doctype[^>]*>", options: [.regularExpression, .caseInsensitive])
            let at = doctype?.upperBound ?? html.startIndex
            return String(html[..<at]) + policy + String(html[at...])
        }

        private func push() {
            guard case .body(let html, let style)? = content else { return }
            let base = folder.flatMap(LocalAssets.url(for:))?.absoluteString ?? ""
            run("window.__mdShow(\(jsLiteral(html)), \(jsLiteral(style)), \(jsLiteral(base)))")
            sync.alignPreview()
        }

        /// What goes inside `<html>`: the page's head and body, without the doctype or the tag itself.
        private static func documentContents(_ html: String) -> String {
            guard let open = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) else { return html }
            let rest = html[open.upperBound...]
            return String(rest[..<(rest.range(of: "</html>", options: [.caseInsensitive, .backwards])?.lowerBound ?? rest.endIndex)])
        }

        func scroll(toLine line: Double) {
            guard loaded, !showingPage, line.isFinite else { return }
            run("window.__mdScrollTo(\(line))")
        }

        /// Page-world scripts are disabled, so app scripts run in the client world (same DOM).
        private func run(_ script: String) {
            webView?.evaluateJavaScript(script + "; 0", in: nil, in: .defaultClient) { result in
                if case .failure(let error) = result { NSLog("preview script failed: %@", String(describing: error)) }
            }
        }

        private func jsLiteral(_ string: String) -> String {
            String(decoding: try! JSONEncoder().encode(string), as: UTF8.self)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "previewComment" {
                // A comment, or {closed} when a box is sent or dropped: its typing is done either way.
                (webView as? FindingWebView)?.forgetTyping()
                if commentable, !showingPage, let body = message.body as? [String: Any],
                   let line = body["line"] as? Int, line > 0, let text = body["text"] as? String, text.utf16.count < 10_000 {
                    comment?(line, text)
                }
                return
            }
            // A rendered web page has no source lines to map, so it doesn't steer the editor.
            if !showingPage, let line = message.body as? Double { sync.scrolled(.preview, toLine: line) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if !showingPage { push() }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Only the app's own loads go through; raw HTML can't redirect, submit, or frame anything.
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                let own = !loaded && action.targetFrame?.isMainFrame == true && action.request.url?.scheme == LocalAssets.scheme
                return own ? .allow : .cancel
            }
            open(url)
            return .cancel
        }

        /// Web and mail links go to their apps; local links open text files here or reveal anything
        /// else in Finder, so a link in an untrusted document never launches a program.
        private func open(_ url: URL) {
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
                NSWorkspace.shared.open(url)
                return
            }
            guard url.scheme == LocalAssets.scheme else { return }
            let path = url.path(percentEncoded: false)
            if path == (folder ?? URL(filePath: "/")).path(percentEncoded: false),
               let fragment = url.fragment(percentEncoded: false) {
                run("document.getElementById(\(jsLiteral(fragment)))?.scrollIntoView({ behavior: 'smooth' })")
            } else if folder != nil {
                let file = URL(filePath: path)
                if FileFormat.all.contains(where: { $0.extensions.contains(file.pathExtension.lowercased()) }) {
                    NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, _ in }
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            }
        }
    }

    /// A string as a JavaScript literal, for the page script's translated text.
    private static func js(_ text: String) -> String { String(decoding: try! JSONEncoder().encode(text), as: UTF8.self) }

    /// Maps between source lines and scroll offsets through the blocks' data-sourcepos lines,
    /// interpolating between neighbours so long paragraphs and images scroll smoothly.
    private static let scrollScript = """
    (() => {
      // Taken from the empty shell: once the document's raw HTML is in, a named element such as
      // `<img name="body">` or `<img name="querySelectorAll">` shadows the document's own property.
      // Elements have no such named lookups, so everything below goes through body and root.
      const body = document.body, root = document.documentElement, base = document.querySelector('base');
      const make = Document.prototype.createElement.bind(document);
      window.__mdShow = (html, style, href) => { base.href = href; body.className = style; body.innerHTML = html; };
      const points = () => {
        const pts = [[0, 0]];
        let end = 0;
        for (const el of body.querySelectorAll('[data-sourcepos]')) {
          const [start, stop] = el.getAttribute('data-sourcepos').split('-').map(p => parseInt(p, 10) - 1);
          const top = el.getBoundingClientRect().top + scrollY;
          const [lastLine, lastTop] = pts[pts.length - 1];
          if (start > lastLine && top > lastTop) pts.push([start, top]);
          end = Math.max(end, stop + 1);
        }
        const bottom = root.scrollHeight - innerHeight;
        const [lastLine, lastTop] = pts[pts.length - 1];
        if (end > lastLine && bottom > lastTop) pts.push([end, bottom]);
        return pts;
      };
      const map = (from, to, value) => {
        const pts = points();
        let i = pts.length - 1;
        while (i > 0 && pts[i][from] > value) i--;
        const a = pts[i], b = pts[i + 1];
        return b ? a[to] + (b[to] - a[to]) * (value - a[from]) / (b[from] - a[from]) : a[to];
      };
      window.__mdScrollTo = line => scrollTo(0, map(0, 1, line));
      // A code card's line number takes a comment: a box opens above the line, Return hands the text
      // to the app, Esc drops it. Return is WebKit's own form submission, which comes after the input
      // method has put in the last Korean syllable. The box stays through a trip to another app, so
      // a half-written comment isn't lost.
      addEventListener('click', event => {
        const number = body.className === 'wide' && event.target.closest && event.target.closest('.code-card.commentable .ln');
        if (!number) return;
        const line = number.parentElement;
        body.querySelector('.comment-draft')?.remove();
        const draft = make('form'), input = make('input'), add = make('button');
        draft.className = 'comment-draft';
        input.placeholder = \(js(String(localized: "주석 입력 후 Return · 취소는 Esc")));
        add.textContent = \(js(String(localized: "추가")));
        draft.append(input, add);
        line.before(draft);
        input.focus();
        const close = message => {
          webkit.messageHandlers.previewComment.postMessage(message);
          draft.remove();
        };
        draft.addEventListener('submit', event => {
          event.preventDefault();
          if (draft.isConnected && input.value.trim()) close({ line: parseInt(line.dataset.sourcepos, 10), text: input.value.trim() });
        });
        input.addEventListener('keydown', key => { if (key.key === 'Escape') close({ closed: true }); });
      });
      addEventListener('scroll', () => webkit.messageHandlers.previewScroll.postMessage(map(1, 0, scrollY)), { passive: true });
    })();
    """
}

/// Takes the Find menu's actions, which a web view leaves disabled, and keeps a comment box's typing
/// apart from the document's undo.
private final class FindingWebView: WKWebView {
    var find: (@MainActor (Selector, Any?) -> Void)?
    /// Typing in a comment box undoes here, so it neither marks the document edited nor makes ⌘Z
    /// take back the document's last change (and re-render the box away) while the box is open.
    private let typingUndo = UndoManager()
    override var undoManager: UndoManager? { typingUndo }

    func forgetTyping() { typingUndo.removeAllActions() }

    /// ⌘Z/⇧⌘Z: the box's typing while there is some, else the document, as the window would.
    @objc func undo(_ sender: Any?) { typingUndo.canUndo ? typingUndo.undo() : window?.undoManager?.undo() }
    @objc func redo(_ sender: Any?) { typingUndo.canRedo ? typingUndo.redo() : window?.undoManager?.redo() }

    override func performTextFinderAction(_ sender: Any?) { find?(#selector(performTextFinderAction(_:)), sender) }
    @objc func performFindPanelAction(_ sender: Any?) { find?(#selector(performFindPanelAction(_:)), sender) }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(performTextFinderAction(_:)), #selector(performFindPanelAction(_:)):
            return true
        case #selector(undo(_:)), #selector(redo(_:)):
            let undoing = item.action == #selector(undo(_:))
            let manager = (undoing ? typingUndo.canUndo : typingUndo.canRedo) ? typingUndo : window?.undoManager
            if let menuItem = item as? NSMenuItem, let manager {
                menuItem.title = undoing ? manager.undoMenuItemTitle : manager.redoMenuItemTitle
            }
            return (undoing ? manager?.canUndo : manager?.canRedo) == true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

/// Serves images, stylesheets and fonts (the document's own, or `../assets/…` beside it) and nothing
/// else, so raw HTML in an untrusted file can't pull other local files (keys, documents) into the
/// preview. With scripts off, what it shows stays on screen.
final class LocalAssets: NSObject, WKURLSchemeHandler {
    static let scheme = "md-local"

    /// file:///a/b/ becomes md-local:///a/b/, keeping the trailing slash relative URLs resolve against.
    static func url(for fileURL: URL) -> URL? {
        var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        // Type-check the symlink's target, or `leak.png -> ~/.ssh/id_ed25519` would pass as an image.
        guard let url = task.request.url,
              case let file = URL(filePath: url.path(percentEncoded: false)).resolvingSymlinksInPath(),
              let mimeType = Self.mimeType(of: file),
              let data = try? Data(contentsOf: file)
        else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
        task.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// Images, fonts and stylesheets; nil for anything else. macOS has no type for web fonts.
    private static func mimeType(of file: URL) -> String? {
        let ext = file.pathExtension.lowercased()
        if let font = ["woff": "font/woff", "woff2": "font/woff2"][ext] { return font }
        guard let type = UTType(filenameExtension: ext),
              type.conforms(to: .image) || type.conforms(to: .font) || type.conforms(to: .css) else { return nil }
        return type.preferredMIMEType
    }
}
