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

    /// Splits off the word under the caret (with its leading space) so the model can
    /// re-predict it: "Давай обсуд" → ("Давай", " обсуд"); "Давай " → ("Давай", " ").
    public static func healingSplit(_ prefix: String) -> (stable: String, target: String)? {
        guard let space = prefix.lastIndex(where: \.isWhitespace), prefix[space] == " " else { return nil }
        let stable = prefix[..<space]
        let target = prefix[space...]
        guard target.count <= 24, let last = stable.last, !last.isWhitespace,
              stable.contains(where: \.isLetter) else { return nil }
        return (String(stable), String(target))
    }

    /// Context window whose start moves in whole `chunk` steps, so consecutive keystrokes
    /// share a prefix and the model's KV cache survives. `text` ends at `location` (UTF-16).
    public static func stableContext(_ text: String, location: Int, minimum: Int, chunk: Int) -> String {
        let length = text.utf16.count
        let step = max(1, chunk)
        let snapped = location > minimum ? ((location - minimum + step - 1) / step) * step : 0
        let drop = snapped - (location - length)
        guard drop > 0, drop < length else { return text }
        var index = String.Index(utf16Offset: drop, in: text)
        while index < text.endIndex, index.samePosition(in: text.unicodeScalars) == nil {
            index = text.utf16.index(after: index)
        }
        var cut = text[index...]
        // Do not open the context in the middle of a word.
        if let space = cut.prefix(48).firstIndex(where: \.isWhitespace) { cut = cut[cut.index(after: space)...] }
        return String(cut)
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
        // Inference is cancellable and takes ~15 ms per token, so the pause only has to
        // absorb fast typing bursts; typed-through suggestions never wait for it.
        debounceMilliseconds = constrained ? 400 : (mode == .responsive ? 50 : 110)
        // A suggestion still ends early at the first doubtful word or the end of a sentence.
        maxTokens = constrained ? 12 : 40
        maxWords = constrained ? 3 : 10
        contextCharacters = constrained ? 300 : 900
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

/// Apps whose message field is invisible to Accessibility. There the text typed since the
/// last click or send is tracked from key events, in memory only.
public enum KeystrokeFallback {
    public static let bundleIDs: [String] = []
    public static func applies(bundleID: String) -> Bool { bundleIDs.contains(bundleID) }
}

/// Text typed since the caret position was last unknown. Anything that may move the caret
/// or change text behind our back resets it, so it never guesses.
public struct TypedBuffer: Sendable {
    public enum Key: Equatable, Sendable { case text(String), backspace, deleteWord, reset }
    public private(set) var text = ""
    public init() {}

    public static func key(keyCode: Int, command: Bool, control: Bool, option: Bool, characters: String) -> Key {
        if command || control { return .reset }
        if keyCode == 51 { return option ? .deleteWord : .backspace }
        // Return, Tab, Enter, Escape, forward delete, Home/End/Page keys, arrows.
        if [36, 48, 76, 53, 117, 115, 119, 116, 121, 123, 124, 125, 126].contains(keyCode) { return .reset }
        let printable = !characters.isEmpty && characters.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }
        return printable ? .text(characters) : .reset
    }

    public mutating func apply(_ key: Key) {
        switch key {
        case .text(let string):
            text += string
            if text.count > 4_000 { text.removeFirst(text.count - 3_000) }
        case .backspace:
            if !text.isEmpty { text.removeLast() }
        case .deleteWord:
            while let last = text.last, last.isWhitespace { text.removeLast() }
            while let last = text.last, !last.isWhitespace { text.removeLast() }
        case .reset:
            text = ""
        }
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

public enum AppVersion {
    /// Numeric comparison of dotted versions: "0.10.0" is newer than "0.9".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int]? {
            let numbers = version.split(separator: ".").map { Int($0) }
            return numbers.isEmpty || numbers.contains(nil) ? nil : numbers.compactMap { $0 }
        }
        guard let new = parts(candidate), let old = parts(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let (a, b) = (index < new.count ? new[index] : 0, index < old.count ? old[index] : 0)
            if a != b { return a > b }
        }
        return false
    }
}
