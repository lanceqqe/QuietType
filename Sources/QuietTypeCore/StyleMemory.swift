import Foundation

/// What the user habitually writes: recent phrases (shown to the model as a style sample),
/// a personal vocabulary and which word tends to follow which. Learned only from text the
/// user typed; stays on this Mac.
public struct StyleMemory: Codable, Sendable, Equatable {
    public struct Sample: Codable, Sendable, Equatable {
        public var text: String
        public var app: String
    }
    public private(set) var samples: [Sample] = []
    /// Lowercased word → times typed.
    public private(set) var words: [String: Int] = [:]
    /// "previous" or "before previous" (lowercased) → next word as typed → times.
    public private(set) var follow: [String: [String: Int]] = [:]

    public init() {}
    public var isEmpty: Bool { samples.isEmpty && words.isEmpty }

    // MARK: Learning

    public mutating func learn(_ text: String, app: String) {
        guard PrivacyGate.allowsContext(text) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            var previous: [String] = []   // normalised words of the current sentence
            for token in tokens {
                guard let word = Self.word(token) else { previous = []; continue }
                let key = word.lowercased()
                words[key, default: 0] += 1
                if let last = previous.last {
                    follow[last, default: [:]][word, default: 0] += 1
                    if previous.count >= 2 {
                        follow[previous[previous.count - 2] + " " + last, default: [:]][word, default: 0] += 1
                    }
                }
                previous.append(key)
                if let end = token.last, ".!?…".contains(end) { previous = [] }
            }
            if tokens.count >= 3, line.count >= 15, Self.isShareable(String(line)) {
                var sample = String(line.prefix(200))
                if line.count > 200, let space = sample.lastIndex(of: " ") { sample = String(sample[..<space]) }
                samples.removeAll { $0.text == sample }
                samples.append(Sample(text: sample, app: app))
            }
        }
        if samples.count > 300 { samples.removeFirst(samples.count - 300) }
        // Words seen once are mostly typos and one-offs; they go first when the store grows.
        if words.count > 20_000 { words = words.filter { $0.value > 1 } }
        if follow.count > 30_000 {
            follow = follow.compactMapValues { next in
                let kept = next.filter { $0.value > 1 }
                return kept.isEmpty ? nil : kept
            }
        }
    }

    /// A plain word without its punctuation; nil for numbers, links, addresses and the like.
    static func word(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        guard !trimmed.isEmpty, trimmed.count <= 32,
              trimmed.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }) else { return nil }
        return trimmed
    }

    private static func isShareable(_ line: String) -> Bool {
        !line.contains("@") && !line.contains("://") &&
            line.range(of: #"\d{4,}"#, options: .regularExpression) == nil
    }

    // MARK: Recall

    /// The user's own usual continuation of `prefix`, when their habit is clear enough.
    public func continuation(of prefix: String, maxWords: Int = 3) -> String? {
        let tail = prefix.suffix(120)
        guard let lastCharacter = tail.last, !lastCharacter.isNewline else { return nil }
        var tokens = tail.split(whereSeparator: \.isWhitespace).map(String.init)
        var partial = ""
        if !lastCharacter.isWhitespace {
            partial = tokens.removeLast()
            guard partial.count >= 2, partial.allSatisfy(\.isLetter) else { return nil }
        } else if lastCharacter != " " { return nil }
        // Context: the words of the current sentence only.
        var context: [String] = []
        for token in tokens {
            guard let word = Self.word(token) else { context = []; continue }
            context.append(word.lowercased())
            if let end = token.last, ".!?…".contains(end) { context = [] }
        }
        var result = ""
        var count = 0
        if !partial.isEmpty {
            guard let word = next(after: context, startingWith: partial) ?? vocabulary(startingWith: partial) else { return nil }
            result = String(word.dropFirst(partial.count))
            context.append(word.lowercased())
            count = 1
        }
        while count < maxWords, let word = next(after: context, startingWith: "") {
            result += (result.isEmpty && partial.isEmpty ? "" : " ") + word
            context.append(word.lowercased())
            count += 1
        }
        return result.isEmpty ? nil : result
    }

    private func next(after context: [String], startingWith partial: String) -> String? {
        guard let last = context.last else { return nil }
        let lowered = partial.lowercased()
        func pick(_ key: String, minimum: Int, share: Double) -> String? {
            guard var options = follow[key] else { return nil }
            if !lowered.isEmpty {
                options = options.filter { $0.key.count > lowered.count && $0.key.lowercased().hasPrefix(lowered) }
            }
            guard let best = options.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value >= minimum,
                  Double(best.value) >= share * Double(options.values.reduce(0, +)) else { return nil }
            return best.key
        }
        if context.count >= 2, let word = pick(context[context.count - 2] + " " + last, minimum: 3, share: 0.5) {
            return word
        }
        return pick(last, minimum: 5, share: 0.6)
    }

    private func vocabulary(startingWith partial: String) -> String? {
        let lowered = partial.lowercased()
        guard lowered.count >= 3 else { return nil }
        let options = words.filter { $0.key.count > lowered.count && $0.key.hasPrefix(lowered) }
        guard let best = options.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value >= 4,
              Double(best.value) >= 0.6 * Double(options.values.reduce(0, +)) else { return nil }
        return partial + best.key.dropFirst(lowered.count)
    }

    /// Recent phrases, the ones written in `app` first, oldest at the top: the model reads
    /// them before the field's text and picks up vocabulary, tone and topics.
    public func styleCard(app: String, limit: Int = 400) -> String {
        var chosen: [(index: Int, text: String)] = []
        var used = 0
        let ordered = samples.enumerated().reversed()
        for (index, sample) in ordered.filter({ $0.element.app == app }) + ordered.filter({ $0.element.app != app }) {
            guard used + sample.text.count + 1 <= limit else { continue }
            chosen.append((index, sample.text))
            used += sample.text.count + 1
        }
        return chosen.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n")
    }
}
