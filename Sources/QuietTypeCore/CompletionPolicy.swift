import Foundation

public enum TextFieldPolicy {
    /// Observation starts on focus, including an empty field. Generation has its own threshold.
    public static func shouldObserve(role: String?, subrole: String?, protected: Bool) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? "") &&
            subrole != "AXSecureTextField" && !protected
    }

    public static func mayGenerate(selectionLength: Int, prefixCount: Int) -> Bool {
        selectionLength == 0 && prefixCount >= 3
    }
}

public enum CompletionText {
    public static func firstWords(_ text: String, count: Int) -> String {
        guard count > 0 else { return "" }
        var remaining = text
        var result = ""
        for _ in 0..<count {
            let word = nextWord(remaining)
            if word.isEmpty { break }
            result += word
            remaining.removeFirst(word.count)
        }
        return result
    }

    public static func nextWord(_ text: String) -> String {
        let leading = text.prefix(while: \.isWhitespace)
        let word = text.dropFirst(leading.count).prefix(while: { !$0.isWhitespace })
        return word.isEmpty ? "" : String(leading + word)
    }

    public static func prefix(_ text: String, utf16Offset: Int) -> String? {
        guard utf16Offset >= 0, utf16Offset <= text.utf16.count,
              let index = String.Index(utf16Offset: utf16Offset, in: text).samePosition(in: text),
              index == text.endIndex || text.indices.contains(index) else { return nil }
        return String(text[..<index])
    }

    public static func clean(_ text: String) -> String {
        let firstLine = String(text.prefix(while: { !$0.isNewline }))
        guard !firstLine.contains("<|"), !firstLine.contains("<think>"),
              !firstLine.contains("�") else { return "" }
        return firstLine
    }

    /// At a token budget boundary, the final word may be only a fragment.
    public static func finished(_ text: String, reachedLimit: Bool) -> String {
        let cleaned = clean(text)
        guard reachedLimit, let last = cleaned.last, !last.isPunctuation else { return cleaned }
        guard let boundary = cleaned.lastIndex(where: \.isWhitespace) else { return "" }
        let complete = cleaned[..<boundary]
        return complete.allSatisfy(\.isWhitespace) ? "" : String(complete)
    }
}

public enum EnergyMode: String, CaseIterable, Sendable {
    case automatic, economy, responsive
    public var title: String {
        switch self {
        case .automatic: "Автоматически"
        case .economy: "Экономия энергии"
        case .responsive: "Быстрый отклик"
        }
    }
}

public enum ThermalLevel: Sendable { case nominal, fair, serious, critical }

public struct EnergyPolicy: Sendable {
    public let debounceMilliseconds: Int
    public let maxTokens: Int
    public let maxWords: Int
    public let contextCharacters: Int
    public let allowsAutomatic: Bool

    public init(mode: EnergyMode, lowPower: Bool, thermal: ThermalLevel) {
        let constrained = lowPower || mode == .economy || thermal == .serious
        debounceMilliseconds = constrained ? 700 : (mode == .responsive ? 220 : 400)
        maxTokens = constrained ? 8 : 16
        maxWords = constrained ? 2 : 3
        contextCharacters = constrained ? 160 : 320
        allowsAutomatic = thermal != .critical
    }
}

public enum PrivacyGate {
    public static let defaults = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "com.agilebits", "com.1password", "com.bitwarden",
        "com.dashlane", "org.keepass", "com.apple.Passwords"
    ]

    public static func isExcluded(bundleID: String, custom: [String]) -> Bool {
        (defaults + custom).contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") ||
            ($0 == "com.agilebits" && bundleID.hasPrefix($0)) }
    }

    public static func allowsContext(_ text: String) -> Bool {
        let patterns = [#"sk-[A-Za-z0-9_-]{16,}"#, #"-----BEGIN .*PRIVATE KEY-----"#,
                        #"(?i)(password|пароль|api[_ -]?key|secret)\s*[:=]\s*\S+"#]
        return !patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}

/// Small, ephemeral cache; callers clear it on focus changes and pause.
public struct CompletionCache {
    private var entries: [(String, String)] = []
    private let capacity: Int
    public init(capacity: Int = 8) { self.capacity = max(1, capacity) }
    public func value(for key: String) -> String? { entries.last(where: { $0.0 == key })?.1 }
    public mutating func insert(_ value: String, for key: String) {
        entries.removeAll { $0.0 == key }
        entries.append((key, value))
        if entries.count > capacity { entries.removeFirst() }
    }
    public mutating func clear() { entries.removeAll(keepingCapacity: false) }
}
