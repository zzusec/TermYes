import AppKit

@MainActor
enum MenuPresentation {
    static let maximumMenuSize = NSSize(width: 280, height: 320)
    static let maximumTitleWidth: CGFloat = 180
    static let agentsPerPage = 6
    static let detailViewportSize = NSSize(width: 320, height: 140)
    static let maximumDetailSize = NSSize(width: 460, height: 360)

    // SwiftUI's menu style uses native item titles, not view frames. Bound the
    // actual single-line title and leave room for checkmarks, icons and arrows.
    static func title(_ text: String) -> String {
        let singleLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let font = NSFont.menuFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (singleLine as NSString).size(withAttributes: attributes).width > maximumTitleWidth else {
            return singleLine
        }
        let characters = Array(singleLine)
        var low = 0
        var high = characters.count
        while low < high {
            let midpoint = (low + high + 1) / 2
            let candidate = String(characters.prefix(midpoint)) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= maximumTitleWidth {
                low = midpoint
            } else {
                high = midpoint - 1
            }
        }
        return String(characters.prefix(low)) + "…"
    }

    static func page<Element>(_ elements: [Element]) -> (visible: [Element], remaining: [Element]) {
        (Array(elements.prefix(agentsPerPage)), Array(elements.dropFirst(agentsPerPage)))
    }

    static func detailsAlert(title: String, detail: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = Self.title(title)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "复制")

        // Every detail uses the same viewport, including short errors containing
        // many newlines or a long URL. The full text remains selectable/copyable.
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: detailViewportSize))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineBreakMode = .byCharWrapping
        text.string = detail
        scroll.documentView = text
        alert.accessoryView = scroll
        return alert
    }
}
