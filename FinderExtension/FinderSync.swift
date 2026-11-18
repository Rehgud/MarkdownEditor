import Cocoa
import FinderSync

/// Finder toolbar button and right-click menu. Asks the (unsandboxed) app to create the file,
/// since this sandboxed extension can't write into arbitrary folders.
final class FinderSync: FIFinderSync {
    private static let askTitle = String(localized: "이름 직접 입력…")
    private static let formats = FileFormat.common + FileFormat.more

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(filePath: "/")]
    }

    override var toolbarItemName: String { String(localized: "새 파일") }
    override var toolbarItemToolTip: String { String(localized: "이 폴더에 새 파일 만들기") }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: String(localized: "새 파일"))!
    }

    /// The toolbar button lists the common formats, the rest under 더 보기; a right-click, on a folder's
    /// background or on a file in it, has the same under 새로 만들기 as on Windows.
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let formats = NSMenu()
        for format in FileFormat.common { formats.addItem(item(Self.title(for: format))) }
        let more = NSMenuItem(title: String(localized: "더 보기"), action: nil, keyEquivalent: "")
        more.submenu = NSMenu()
        for format in FileFormat.more { more.submenu?.addItem(item(Self.title(for: format))) }
        formats.addItem(more)
        formats.addItem(.separator())
        formats.addItem(item(Self.askTitle))
        switch menuKind {
        case .toolbarItemMenu:
            return formats
        case .contextualMenuForContainer, .contextualMenuForItems:
            let menu = NSMenu()
            let new = NSMenuItem(title: String(localized: "새로 만들기"), action: nil, keyEquivalent: "")
            new.submenu = formats
            menu.addItem(new)
            return menu
        default:
            return nil
        }
    }

    private static func title(for format: FileFormat) -> String { "\(format.name) (.\(format.fileExtension))" }

    private func item(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: #selector(newFile(_:)), keyEquivalent: "")
    }

    /// Finder rebuilds the menu in its own process and hands back a stand-in item; its title is what
    /// survives the trip (Apple's FinderSync sample reads it too), so the title says which format.
    @objc private func newFile(_ sender: NSMenuItem) {
        // The folder the menu was opened in, also when it was opened on a file.
        guard let folder = FIFinderSyncController.default().targetedURL() else { return }
        var query = [URLQueryItem(name: "dir", value: folder.path(percentEncoded: false))]
        if sender.title == Self.askTitle {
            query.append(URLQueryItem(name: "ask", value: "1"))
        } else if let format = Self.formats.first(where: { Self.title(for: $0) == sender.title }) {
            query.append(URLQueryItem(name: "ext", value: format.fileExtension))
        } else {
            return
        }
        var components = URLComponents()
        components.scheme = "markdowneditor"
        components.host = "new"
        components.queryItems = query
        NSWorkspace.shared.open(components.url!)
    }
}
