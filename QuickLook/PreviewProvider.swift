import QuickLookUI
import UniformTypeIdentifiers

/// Finder's space-bar preview for .md, rendered with the same HTML and CSS as the app.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        // Read as the app reads it, so a UTF-16 or CP949 file previews too.
        guard let markdown = decodeText(try Data(contentsOf: request.fileURL))?.text else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let html = Data(previewHTML(body: renderMarkdown(markdown)).utf8)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 1000)) { _ in html }
    }
}
