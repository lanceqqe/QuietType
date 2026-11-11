import CoreML
import Foundation
import Tokenizers

public enum ModelFailure: LocalizedError {
    case missingFiles, incompatibleModel, emptyContext
    public var errorDescription: String? {
        switch self {
        case .missingFiles: "Модель не установлена. Откройте раздел «Модель» и скачайте файлы."
        case .incompatibleModel: "Формат модели не подходит. Переустановите модель в разделе «Модель»."
        case .emptyContext: "Напишите несколько слов для продолжения."
        }
    }
}

public struct InferenceResult: Sendable {
    public let text: String
    public let tokenCount: Int
    public let milliseconds: Double
    public let reusedTokens: Int
    public init(text: String, tokenCount: Int, milliseconds: Double, reusedTokens: Int) {
        self.text = text; self.tokenCount = tokenCount; self.milliseconds = milliseconds; self.reusedTokens = reusedTokens
    }
}

/// Highest-scoring next tokens, best first, with the log-normaliser of the distribution
/// (of the whole vocabulary, or of the per-slice maxima for argmax heads).
struct Candidates: Sendable {
    let ids: [Int]
    let logits: [Float]
    let logSum: Float
}

/// Confidence floors for cutting a suggestion short. They depend on how peaked a model's
/// distribution is, so each model carries its own calibration.
public struct DecodingProfile: Sendable {
    /// Minimum probability of the first free token, of a later token that starts a word,
    /// and of a later token that continues one.
    public var firstFloor: Float
    public var wordFloor: Float
    public var innerFloor: Float
    /// Words offered before `wordFloor` starts to apply: a short guess is cheap to ignore,
    /// only the tail of a long suggestion has to be earned by confidence.
    public var freeWords: Int
    public init(firstFloor: Float, wordFloor: Float, innerFloor: Float, freeWords: Int = 3) {
        self.firstFloor = firstFloor; self.wordFloor = wordFloor; self.innerFloor = innerFloor
        self.freeWords = freeWords
    }
}

/// One actor owns the model, state and reusable input buffers.
public actor LocalModel {
    /// The transformer may be split into several Core ML chunks, each with its own KV state.
    private var chunks: [(infer: MLModel, prefill: MLModel)] = []
    private var states: [MLState] = []
    private var embeddings: MLModel?
    private var head: MLModel?
    private var headOutputs: [String] = []
    /// Vocabulary slice covered by each output of an argmax head.
    private var argmaxSliceSize = 16_384
    private var tokenizer: (any Tokenizer)?
    private var stopTokens = Set<Int>()
    private var leadingTokens: [Int] = []
    private var profile = ModelAssets.profile
    private var processed: [Int] = []
    private var promptCandidates: (length: Int, candidates: Candidates)?
    /// Tokens of the last style sample, so an unchanged one is not tokenized per keystroke.
    private var leadTokens: (text: String, chat: Bool, tokens: [Int]) = ("", false, [])
    /// Gemma's turn markers; nil for models without them, which get the lead as plain text.
    private var turnTokens: (start: Int, end: Int)?
    private var ids: MLMultiArray?
    private var positions: MLMultiArray?
    private var mask: MLMultiArray?
    private var batchIDs: MLMultiArray?
    private var batchPositions: MLMultiArray?
    private var batchMask: MLMultiArray?
    /// Width of the causal mask the model was converted with.
    private var maskWidth = 512
    /// Tokens actually used: the lead and the 900-character field window.
    /// Capped at 1024, where the conversion works without KV rotation.
    private var contextLength = 512
    private let batch = 64
    /// Where the loaded model runs; empty until loaded.
    public private(set) var computeUnits = ""
    /// Why a preferred compute unit was skipped during the last load, for the diagnostic log.
    public private(set) var loadNotes: [String] = []

    public init() {}

    public func load(from directory: URL, profile: DecodingProfile = ModelAssets.profile,
                     neuralEngine: Bool = true) async throws {
        guard chunks.isEmpty else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path)
        else { throw ModelFailure.missingFiles }
        let localTokenizer = try await AutoTokenizer.from(modelFolder: directory)
        try Task.checkCancellation()
        // ANEMLL layout: <prefix>_embeddings*, <prefix>_FFN_PF*_chunk_NNofMM, <prefix>_lm_head*.
        let parts = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".mlmodelc") }.map { String($0.dropLast(9)) }.sorted()
        let chunkNames = parts.filter { $0.contains("_FFN_PF") }
        guard let embeddingName = parts.first(where: { $0.contains("_embeddings") }),
              let headName = parts.first(where: { $0.contains("_lm_head") }),
              !chunkNames.isEmpty else { throw ModelFailure.missingFiles }
        // The Neural Engine is the efficient path, but on some Mac / macOS combinations Core ML
        // refuses to load the stateful functions there. The same files then run on the GPU or CPU.
        let attempts: [(MLComputeUnits, String)] = [
            (.cpuAndNeuralEngine, "CPU + Neural Engine"), (.cpuAndGPU, "CPU + GPU"), (.cpuOnly, "CPU")
        ]
        var loadedParts: (embedding: MLModel, chunks: [(infer: MLModel, prefill: MLModel)], head: MLModel)?
        var failure: Error = ModelFailure.incompatibleModel
        loadNotes = []
        for (units, title) in attempts.dropFirst(neuralEngine ? 0 : 1) {
            func loadPart(_ name: String, function: String? = nil) throws -> MLModel {
                let config = MLModelConfiguration()
                config.computeUnits = units
                config.functionName = function
                return try MLModel(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: config)
            }
            do {
                let embedding = try loadPart(embeddingName)
                var loaded: [(infer: MLModel, prefill: MLModel)] = []
                for name in chunkNames {
                    try Task.checkCancellation()
                    loaded.append((try loadPart(name, function: "infer"), try loadPart(name, function: "prefill")))
                }
                loadedParts = (embedding, loaded, try loadPart(headName))
                computeUnits = title
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
                let detail = error as NSError
                let cause = (detail.userInfo[NSUnderlyingErrorKey] as? NSError).map { " ← \($0.domain) \($0.code): \($0.localizedDescription)" } ?? ""
                loadNotes.append("\(title) rejected: \(detail.domain) \(detail.code): \(detail.localizedDescription)\(cause)")
            }
        }
        guard let loadedParts else { throw failure }
        let embeddingModel = loadedParts.embedding
        let loaded = loadedParts.chunks
        let headModel = loadedParts.head
        try Task.checkCancellation()
        guard let width = loaded[0].infer.modelDescription.inputDescriptionsByName["causal_mask"]?
            .multiArrayConstraint?.shape.last?.intValue, width >= 64 else { throw ModelFailure.incompatibleModel }
        let outputs = headModel.modelDescription.outputDescriptionsByName.keys
        if outputs.contains("argmax_idx"), outputs.contains("argmax_val") {
            headOutputs = []
            // The slice size is not in the compiled model; ANEMLL records the vocabulary in meta.yaml.
            let meta = (try? String(contentsOf: directory.appendingPathComponent("meta.yaml"), encoding: .utf8)) ?? ""
            let slices = headModel.modelDescription.outputDescriptionsByName["argmax_idx"]?
                .multiArrayConstraint?.shape.first?.intValue ?? 16
            if let line = meta.split(whereSeparator: \.isNewline).first(where: { $0.contains("vocab_size:") && !$0.contains("#") }),
               let vocabulary = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)), slices > 0 {
                argmaxSliceSize = (vocabulary + slices - 1) / slices
            }
        } else {
            headOutputs = (1...outputs.count).map { "logits\($0)" }
            guard headOutputs.allSatisfy(outputs.contains) else { throw ModelFailure.incompatibleModel }
        }
        maskWidth = width
        contextLength = min(1024, width)
        stopTokens = Set(["<|endoftext|>", "<|im_end|>", "<eos>", "<end_of_turn>"]
            .compactMap(localTokenizer.convertTokenToId) + [localTokenizer.eosTokenId].compactMap { $0 })
        // Gemma expects its BOS token in front of raw text; Qwen has none.
        leadingTokens = localTokenizer.convertTokenToId("<bos>").map { [$0] } ?? []
        if let start = localTokenizer.convertTokenToId("<start_of_turn>"), let end = localTokenizer.convertTokenToId("<end_of_turn>") {
            turnTokens = (start, end)
        }
        self.profile = profile
        embeddings = embeddingModel
        head = headModel
        ids = try MLMultiArray(shape: [1, 1], dataType: .int32)
        positions = try MLMultiArray(shape: [1], dataType: .int32)
        mask = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: width)], dataType: .float16)
        batchIDs = try MLMultiArray(shape: [1, NSNumber(value: batch)], dataType: .int32)
        batchPositions = try MLMultiArray(shape: [NSNumber(value: batch)], dataType: .int32)
        batchMask = try MLMultiArray(shape: [1, 1, NSNumber(value: batch), NSNumber(value: width)], dataType: .float16)
        tokenizer = localTokenizer
        chunks = loaded
        resetContext()
    }

    public func resetContext() {
        processed.removeAll(keepingCapacity: false)
        promptCandidates = nil
        states = chunks.map { $0.infer.makeState() }
    }

    public func unload() {
        states = []
        chunks = []
        computeUnits = ""
        embeddings = nil; head = nil
        tokenizer = nil
        processed = []
        promptCandidates = nil
        ids = nil; positions = nil; mask = nil
        batchIDs = nil; batchPositions = nil; batchMask = nil
    }

    public func complete(
        prefix: String, lead: String = "", chat: Bool = true, maxTokens: Int, maxWords: Int = 3,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) throws -> InferenceResult {
        guard tokenizer != nil, !chunks.isEmpty else { throw ModelFailure.missingFiles }
        let start = ContinuousClock.now
        // Token healing: re-predict the word under the caret instead of trusting the
        // tokenization of a half-typed word. Falls back to plain continuation.
        var reused = 0
        var outcome: (text: String, tokens: Int)?
        if let split = CompletionText.healingSplit(prefix) {
            outcome = try generate(context: split.stable, lead: lead, chat: chat, target: split.target, maxTokens: maxTokens,
                                   maxWords: maxWords, reused: &reused, onPartial: onPartial)
        }
        if outcome == nil {
            outcome = try generate(context: prefix, lead: lead, chat: chat, target: "", maxTokens: maxTokens,
                                   maxWords: maxWords, reused: &reused, onPartial: onPartial)
        }
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        return InferenceResult(text: outcome?.text ?? "", tokenCount: outcome?.tokens ?? 0,
                               milliseconds: milliseconds, reusedTokens: reused)
    }

    /// Share of next tokens of `text` the model ranks first, fed token by token as it is typed.
    /// A calibration tool for ModelProbe: it compares models by number instead of by eye.
    public func score(_ text: String, lead: String = "", chat: Bool = true) throws -> (tokens: Int, top1: Double) {
        guard let tokenizer else { throw ModelFailure.missingFiles }
        let fixed = try fixedTokens(lead: lead, chat: chat)
        let tokens = Array((fixed + tokenizer.encode(text: text, addSpecialTokens: false)).prefix(contextLength))
        guard tokens.count > fixed.count else { throw ModelFailure.emptyContext }
        resetContext()
        defer { resetContext() }
        var hits = 0
        for position in 0..<(tokens.count - 1) {
            let best = try predict(tokens[position], at: position).ids.first
            if position >= fixed.count - 1, best == tokens[position + 1] { hits += 1 }
        }
        let scored = tokens.count - fixed.count
        return (scored, Double(hits) / Double(scored))
    }

    /// Everything in front of the field's text: BOS and the lead (what the user is looking
    /// at, how they write). A fixed block, so its KV cache survives from one request to the next.
    /// An instruction-tuned model reads the lead as a request and continues the field's text
    /// as its own answer, which keeps it from carrying on the lead itself.
    private func fixedTokens(lead: String, chat: Bool) throws -> [Int] {
        guard let tokenizer else { throw ModelFailure.missingFiles }
        if lead != leadTokens.text || chat != leadTokens.chat {
            var tokens: [Int] = []
            if !lead.isEmpty {
                if chat, let turn = turnTokens {
                    tokens = [turn.start] + tokenizer.encode(text: "user\n" + lead, addSpecialTokens: false) + [turn.end]
                        + tokenizer.encode(text: "\n", addSpecialTokens: false) + [turn.start]
                        + tokenizer.encode(text: "model\n", addSpecialTokens: false)
                } else {
                    tokens = tokenizer.encode(text: lead + "\n\n", addSpecialTokens: false)
                }
            }
            leadTokens = (lead, chat, tokens)
        }
        return leadingTokens + leadTokens.tokens
    }

    /// Returns nil only when `target` could not be reproduced by the model's top candidates.
    private func generate(
        context: String, lead: String, chat: Bool, target: String, maxTokens: Int, maxWords: Int, reused: inout Int,
        onPartial: (@Sendable (String) -> Void)?
    ) throws -> (text: String, tokens: Int)? {
        guard let tokenizer else { throw ModelFailure.missingFiles }
        let budget = min(48, max(1, maxTokens))
        let wordLimit = min(12, max(1, maxWords))
        let healingBudget = 12
        var tokens = tokenizer.encode(text: context, addSpecialTokens: false)
        var fixed = try fixedTokens(lead: lead, chat: chat)
        // A lead that would crowd out the field's own text is dropped whole.
        if fixed.count > contextLength - 320 { fixed = leadingTokens }
        let room = contextLength - budget - healingBudget - fixed.count
        if tokens.count > room {
            // Drop whole blocks so the window start (and the KV cache) stays put while typing.
            tokens.removeFirst(min(tokens.count - 1, ((tokens.count - room + 63) / 64) * 64))
        }
        guard !tokens.isEmpty else { throw ModelFailure.emptyContext }
        tokens.insert(contentsOf: fixed, at: 0)
        var common = 0
        while common < min(tokens.count, processed.count), tokens[common] == processed[common] { common += 1 }
        // KV entries after the common prefix are masked until overwritten.
        if common == 0 { resetContext() }
        if common < processed.count { processed.removeSubrange(common...) }
        if let saved = promptCandidates, saved.length > common || (saved.length != tokens.count && common == tokens.count) {
            promptCandidates = nil
        }
        var candidates: Candidates
        if common == tokens.count, let saved = promptCandidates, saved.length == tokens.count {
            candidates = saved.candidates
        } else {
            if common == tokens.count {
                common -= 1
                processed.removeLast()
            }
            // Batch all but the final prompt token. The final token produces logits.
            var cursor = common
            while cursor < tokens.count - 1 {
                try Task.checkCancellation()
                if cursor + 64 > contextLength {
                    _ = try predict(tokens[cursor], at: cursor)
                    processed.append(tokens[cursor])
                    cursor += 1
                    continue
                }
                let count = min(64, tokens.count - 1 - cursor)
                try prefillTokens(Array(tokens[cursor..<(cursor + count)]), at: cursor)
                processed.append(contentsOf: tokens[cursor..<(cursor + count)])
                cursor += count
            }
            candidates = try predict(tokens[cursor], at: cursor)
            processed.append(tokens[cursor])
            promptCandidates = (tokens.count, candidates)
        }
        reused = max(reused, common)

        let typedLine = String((context + target).suffix(160).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? "")
        let leadLines = lead.lowercased().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let foreignContext = Self.hasForeignLetters(context + target)
        let typedLetters = (context + target).reversed().prefix(while: \.isLetter).count
        var generated: [Int] = []
        var remainder = target
        var healed = 0
        var free = 0
        var accepted = ""          // text made only of confident tokens
        var publishedWordCount = 0
        var cutShort = false
        func display(_ text: String) -> String? {
            guard text.hasPrefix(target) else { return nil }
            return String(text.dropFirst(target.count))
        }
        while true {
            try Task.checkCancellation()
            if !remainder.isEmpty {
                // A token may run past the typed fragment (finish the word), except when the
                // fragment is one or two letters: that is usually a word of its own.
                let mayExtend = typedLetters >= 3 || !remainder.contains(where: \.isLetter)
                guard healed < healingBudget, let pick = forced(candidates, remainder: remainder, mayExtend: mayExtend) else { return nil }
                // A token that runs past what was typed is the model's first guess, and has
                // to be as sure as any other first token.
                if pick.piece.count > remainder.count, pick.probability < profile.firstFloor { return ("", generated.count) }
                remainder = String(remainder.dropFirst(pick.piece.count))
                healed += 1
                generated.append(pick.id)
            } else {
                guard free < budget else { cutShort = true; break }
                guard var pick = choose(candidates, history: Array(processed.dropFirst(fixed.count))) else { cutShort = true; break }
                // One or two typed letters are usually a whole word ("в", "на", "да"): offer
                // what follows it rather than stretching it into another word.
                if free == 0, (1...2).contains(typedLetters), pick.piece.first?.isLetter == true {
                    guard let next = candidates.ids.indices.lazy.map({ (id: candidates.ids[$0],
                        probability: exp(candidates.logits[$0] - candidates.logSum), piece: tokenizer.decode(tokens: [candidates.ids[$0]])) })
                        .first(where: { $0.piece.first.map { !$0.isLetter && !$0.isNumber } == true }) else { break }
                    pick = next
                }
                if stopTokens.contains(pick.id) { break }
                // Numbers are guesses (a time, a count copied from the screen), and a hyphen
                // glued to a finished word ("что" → "что-то") rewrites what the user meant.
                // So is a word in a script the user is not writing in.
                if pick.piece.contains(where: \.isNumber) || (free == 0 && pick.piece.hasPrefix("-"))
                    || (!foreignContext && Self.hasForeignLetters(pick.piece)) {
                    cutShort = pick.piece.first?.isWhitespace != true
                    break
                }
                // A doubtful token ends the suggestion at the last finished word.
                let startsWord = pick.piece.first?.isWhitespace == true
                let floor: Float = if free == 0 && healed == 0 { profile.firstFloor }
                    else if startsWord { publishedWordCount < profile.freeWords ? 0 : profile.wordFloor }
                    else { profile.innerFloor }
                if pick.probability < floor { cutShort = !startsWord; break }
                free += 1
                generated.append(pick.id)
            }
            let text = tokenizer.decode(tokens: generated)
            if remainder.isEmpty {
                guard let shown = display(text) else { return nil }
                if shown.contains(where: \.isNewline) { break }
                if !text.contains("�") {
                    // A message that repeats a line of the lead from its first word is the
                    // other person's line read back, not what the user is about to write.
                    let message = (typedLine + shown).trimmingCharacters(in: .whitespaces).lowercased()
                    if free > 0, message.split(separator: " ").count >= 3, leadLines.contains(where: { $0.hasPrefix(message) }) {
                        return ("", generated.count)
                    }
                    accepted = shown
                    let partial = CompletionText.firstWords(CompletionText.finished(shown, reachedLimit: true), count: wordLimit)
                    let wordCount = partial.split(whereSeparator: \.isWhitespace).count
                    if wordCount > publishedWordCount {
                        onPartial?(partial)
                        publishedWordCount = wordCount
                    }
                    // Stop once the requested words are complete or the sentence ended.
                    if wordCount >= wordLimit { cutShort = true; break }
                    if free > 0, let last = shown.last, ".!?…".contains(last) { break }
                }
            }
            guard processed.count < contextLength - 1, let token = generated.last else { cutShort = true; break }
            candidates = try predict(token, at: processed.count)
            processed.append(token)
        }
        let finished = CompletionText.finished(accepted, reachedLimit: cutShort)
        return (CompletionText.firstWords(finished, count: wordLimit), generated.count)
    }

    /// Letters outside Latin and Cyrillic: a suggestion in Thai for a Russian message is noise.
    private static func hasForeignLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x52F && !(0x1E00...0x1EFF).contains($0.value) }
    }

    /// Best candidate that agrees with the text the user already typed.
    private func forced(_ candidates: Candidates, remainder: String, mayExtend: Bool) -> (id: Int, piece: String, probability: Float)? {
        guard let tokenizer else { return nil }
        var best: (id: Int, piece: String, logit: Float)?
        // Probability among the candidates that agree with the typed text: the rest are ruled out.
        var mass: Float = 0
        for (index, id) in candidates.ids.enumerated() {
            let piece = tokenizer.decode(tokens: [id])
            guard !piece.isEmpty, !piece.contains("�") else { continue }
            if remainder.hasPrefix(piece) || (mayExtend && piece.hasPrefix(remainder)) {
                if best == nil { best = (id, piece, candidates.logits[index]) }
                mass += exp(candidates.logits[index] - candidates.logSum)
            }
        }
        guard let best else { return nil }
        return (best.id, best.piece, exp(best.logit - candidates.logSum) / mass)
    }

    /// Greedy choice that refuses to walk into a loop already present in the text.
    private func choose(_ candidates: Candidates, history: [Int]) -> (id: Int, probability: Float, piece: String)? {
        guard let tokenizer else { return nil }
        var banned = Set<Int>()
        for (size, window) in [(3, 256), (2, 40)] where history.count > size {
            let recent = Array(history.suffix(window))
            let tail = Array(recent.suffix(size))
            for i in 0..<(recent.count - size) where Array(recent[i..<(i + size)]) == tail {
                banned.insert(recent[i + size])
            }
        }
        for (index, id) in candidates.ids.enumerated() where !banned.contains(id) {
            return (id, exp(candidates.logits[index] - candidates.logSum), tokenizer.decode(tokens: [id]))
        }
        return nil
    }

    private func predict(_ token: Int, at position: Int) throws -> Candidates {
        guard position < contextLength, states.count == chunks.count, let embeddings, let head,
              let ids, let positions, let mask else { throw ModelFailure.incompatibleModel }
        ids[0] = NSNumber(value: token)
        positions[0] = NSNumber(value: position)
        let maskValues = mask.dataPointer.bindMemory(to: Float16.self, capacity: maskWidth)
        for i in 0..<maskWidth {
            maskValues[i] = i <= position ? 0 : -Float16.infinity
        }
        let embedded = try embeddings.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids)
        ]))
        guard var hidden = embedded.featureValue(for: "hidden_states") else { throw ModelFailure.incompatibleModel }
        for (chunk, state) in zip(chunks, states) {
            let output = try chunk.infer.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "hidden_states": hidden,
                "position_ids": MLFeatureValue(multiArray: positions),
                "current_pos": MLFeatureValue(multiArray: positions),
                "causal_mask": MLFeatureValue(multiArray: mask)
            ]), using: state)
            guard let next = output.featureValue(for: "output_hidden_states") else { throw ModelFailure.incompatibleModel }
            hidden = next
        }
        let logits = try head.prediction(from: MLDictionaryFeatureProvider(dictionary: ["hidden_states": hidden]))
        if headOutputs.isEmpty {
            // Argmax head: the best token of each vocabulary slice and its logit, nothing else.
            guard let indices = logits.featureValue(for: "argmax_idx")?.multiArrayValue,
                  let values = logits.featureValue(for: "argmax_val")?.multiArrayValue,
                  indices.count == values.count else { throw ModelFailure.incompatibleModel }
            let slice = argmaxSliceSize
            let pairs = (0..<indices.count).map { (indices[$0].intValue + $0 * slice, values[$0].floatValue) }
                .sorted { $0.1 > $1.1 }
            // Normalising over the slice maxima alone gives an upper bound on the probability:
            // close rivals usually sit in other slices, so a low value still means real doubt.
            let top = pairs[0].1
            let logSum = top + log(pairs.reduce(Float(0)) { $0 + exp($1.1 - top) })
            return Candidates(ids: pairs.map(\.0), logits: pairs.map(\.1), logSum: logSum)
        }
        var arrays: [MLMultiArray] = []
        for name in headOutputs {
            guard let array = logits.featureValue(for: name)?.multiArrayValue,
                  array.dataType == .float16, array.strides.last?.intValue == 1 else { throw ModelFailure.incompatibleModel }
            arrays.append(array)
        }
        // One pass keeps the top candidates; a second one normalises them into probabilities.
        let keep = 32
        var topIDs = [Int](repeating: -1, count: keep)
        var topValues = [Float16](repeating: -.infinity, count: keep)
        var weakest = 0
        var threshold: Float16 = -.infinity
        var best: Float16 = -.infinity
        var offset = 0
        for array in arrays {
            let values = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            for i in 0..<array.count where values[i] > threshold {
                topValues[weakest] = values[i]
                topIDs[weakest] = offset + i
                if values[i] > best { best = values[i] }
                threshold = topValues[0]; weakest = 0
                for j in 1..<keep where topValues[j] < threshold { threshold = topValues[j]; weakest = j }
            }
            offset += array.count
        }
        var sum: Float = 0
        let reference = Float(best)
        for array in arrays {
            let values = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            for i in 0..<array.count { sum += exp(Float(values[i]) - reference) }
        }
        let order = (0..<keep).filter { topIDs[$0] >= 0 }.sorted { topValues[$0] > topValues[$1] }
        return Candidates(ids: order.map { topIDs[$0] }, logits: order.map { Float(topValues[$0]) },
                          logSum: reference + log(sum))
    }

    private func prefillTokens(_ tokens: [Int], at position: Int) throws {
        guard let embeddings, states.count == chunks.count,
              let ids = batchIDs, let positions = batchPositions, let mask = batchMask else { throw ModelFailure.missingFiles }
        let current = try MLMultiArray(shape: [1], dataType: .int32)
        current[0] = NSNumber(value: position)
        let values = mask.dataPointer.bindMemory(to: Float16.self, capacity: batch * maskWidth)
        for row in 0..<batch {
            ids[row] = NSNumber(value: row < tokens.count ? tokens[row] : 0)
            positions[row] = NSNumber(value: position + row)
            for col in 0..<maskWidth {
                values[row * maskWidth + col] = col <= position + row ? 0 : -Float16.infinity
            }
        }
        let embedded = try embeddings.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids)
        ]))
        guard var hidden = embedded.featureValue(for: "hidden_states") else { throw ModelFailure.incompatibleModel }
        for (index, (chunk, state)) in zip(chunks, states).enumerated() {
            let output = try chunk.prefill.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "hidden_states": hidden, "position_ids": MLFeatureValue(multiArray: positions),
                "current_pos": MLFeatureValue(multiArray: current), "causal_mask": MLFeatureValue(multiArray: mask)
            ]), using: state)
            guard index < chunks.count - 1 else { break }
            guard let next = output.featureValue(for: "output_hidden_states") else { throw ModelFailure.incompatibleModel }
            hidden = next
        }
    }
}
