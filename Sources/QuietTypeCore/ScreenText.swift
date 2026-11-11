import CoreGraphics
import Foundation

/// Turns pieces of text found in a window into the lines a person would read above the
/// field they are typing in: the conversation or the letter being answered.
public enum ScreenText {
    public struct Fragment: Sendable {
        public let text: String
        /// Top-left origin, y grows downwards (Accessibility and image coordinates alike).
        public let frame: CGRect
        public init(text: String, frame: CGRect) { self.text = text; self.frame = frame }
    }

    /// One piece of screen text without what the model would only parrot: message times,
    /// delivery ticks, counters. Empty when nothing readable is left.
    public static func clean(_ text: String) -> String {
        let words = text.replacingOccurrences(of: #"\b\d{1,2}[:.]\d{2}(:\d{2})?\b|[✓✔☑]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
        let line = words.joined(separator: " ")
        return line.filter(\.isLetter).count >= 2 ? line : ""
    }

    /// Keeps fragments above `field` and in its column, in reading order, and returns the
    /// `limit` characters closest to the field, starting at a line or word boundary.
    public static func assemble(_ fragments: [Fragment], field: CGRect, limit: Int = 600) -> String {
        let column = field.insetBy(dx: -24, dy: 0)
        var rows: [(text: String, frame: CGRect)] = []
        for fragment in fragments {
            let frame = fragment.frame
            guard frame.midY < field.minY, frame.maxX > column.minX, frame.minX < column.maxX else { continue }
            let text = clean(fragment.text)
            if !text.isEmpty { rows.append((text, frame)) }
        }
        rows.sort { first, second in
            let sameRow = abs(first.frame.midY - second.frame.midY) <= 6
            return sameRow ? first.frame.minX < second.frame.minX : first.frame.midY < second.frame.midY
        }
        var lines: [String] = []
        var lastY = -CGFloat.infinity
        for row in rows {
            if abs(row.frame.midY - lastY) <= 6, !lines.isEmpty { lines[lines.count - 1] += " " + row.text }
            else if lines.last != row.text { lines.append(row.text) }
            lastY = row.frame.midY
        }
        var text = lines.joined(separator: "\n")
        guard text.count > limit else { return PrivacyGate.allowsContext(text) ? text : "" }
        text = String(text.suffix(limit))
        if let cut = text.firstIndex(where: \.isNewline) ?? text.firstIndex(of: " ") { text = String(text[text.index(after: cut)...]) }
        return PrivacyGate.allowsContext(text) ? text : ""
    }
}
