import QuickLookUI
import UniformTypeIdentifiers

/// Finder's space-bar preview for .md, rendered with the same HTML and CSS as the app.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let markdown = try String(contentsOf: request.fileURL, encoding: .utf8)
        let html = Data(previewHTML(body: renderMarkdown(markdown)).utf8)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 1000)) { _ in html }
    }
}
