import AppKit

/// AX attributed strings use AXFont/AXForegroundColor, not NSFont/NSColor keys.
public struct HostTextStyle {
    public let font: NSFont
    public let color: NSColor

    public init(attributes: [NSAttributedString.Key: Any], caretHeight: CGFloat) {
        let axFont = attributes[NSAttributedString.Key("AXFont")] as? [String: Any]
        let size = (axFont?["AXFontSize"] as? NSNumber)?.doubleValue
        let name = axFont?["AXFontName"] as? String
        if let native = attributes[.font] as? NSFont {
            font = native
        } else if let size, size.isFinite, size >= 6, size <= 128 {
            font = name.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
        } else {
            font = NSFont.systemFont(ofSize: max(11, min(24, caretHeight / 1.2)))
        }
        if let native = attributes[.foregroundColor] as? NSColor {
            color = native
        } else if let raw = attributes[NSAttributedString.Key("AXForegroundColor")],
                  CFGetTypeID(raw as CFTypeRef) == CGColor.typeID {
            color = NSColor(cgColor: unsafeDowncast(raw as CFTypeRef, to: CGColor.self)) ?? .labelColor
        } else {
            color = .labelColor
        }
    }
}
