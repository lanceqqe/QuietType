import AppKit

/// A transparent drawing surface, not a popover: only ghost glyphs are visible.
@MainActor
final class SuggestionPanel {
    private let panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }()

    func show(_ suggestion: String, caret: CGRect, container: CGRect, font: NSFont, color: NSColor) {
        guard !suggestion.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret) }) ?? NSScreen.main else {
            hide(); return
        }
        let lineHeight = max(caret.height, ceil(font.ascender - font.descender + font.leading))
        let left = max(container.minX, screen.visibleFrame.minX)
        let right = min(container.maxX, screen.visibleFrame.maxX)
        let top = caret.maxY
        let height = min(lineHeight * 3, max(lineHeight, top - max(container.minY, screen.visibleFrame.minY)))
        guard right - caret.minX > 10, right - left > 20 else { hide(); return }
        let view = GhostTextView(frame: CGRect(x: 0, y: 0, width: right - left, height: height))
        view.configure(text: suggestion, font: font, color: color.withAlphaComponent(0.45),
                       firstLineOffset: max(0, caret.minX - left), lineHeight: lineHeight)
        panel.contentView = view
        panel.setFrame(CGRect(x: left, y: top - height, width: right - left, height: height), display: true)
        panel.orderFrontRegardless()
    }

    /// Fallback for hosts that expose no caret geometry: a compact label near the field
    /// (or above the bottom edge of the window when even the field is unknown).
    func showPill(_ suggestion: String, anchor: CGRect, insideWindow: Bool) {
        let text = suggestion.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else {
            hide(); return
        }
        let label = NSTextField(labelWithAttributedString: {
            let string = NSMutableAttributedString(string: "⇥  ", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            string.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
            return string
        }())
        label.lineBreakMode = .byTruncatingTail
        let fitting = label.fittingSize
        let size = CGSize(width: min(460, ceil(fitting.width) + 22), height: ceil(fitting.height) + 10)
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.setAccessibilityElement(false)
        label.frame = CGRect(x: 11, y: 5, width: size.width - 22, height: ceil(fitting.height))
        background.addSubview(label)
        var origin = insideWindow
            ? CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY + 84)
            : CGPoint(x: anchor.minX, y: anchor.maxY + 6)
        let visible = screen.visibleFrame
        if !insideWindow, origin.y + size.height > visible.maxY { origin.y = anchor.minY - size.height - 6 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        panel.contentView = background
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

@MainActor
final class GhostTextView: NSView {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer()
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 3
        container.lineBreakMode = .byWordWrapping
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    func configure(text: String, font: NSFont, color: NSColor, firstLineOffset: CGFloat, lineHeight: CGFloat) {
        container.containerSize = bounds.size
        if firstLineOffset > 0 {
            container.exclusionPaths = [NSBezierPath(rect: CGRect(x: 0, y: 0, width: firstLineOffset, height: lineHeight - 1))]
        } else {
            container.exclusionPaths = []
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ]))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyphs = layout.glyphRange(for: container)
        layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }
}
