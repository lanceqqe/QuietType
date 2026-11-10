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
}

/// One actor owns the model, state and reusable input buffers. No Metal / GPU path.
public actor LocalModel {
    private var model: MLModel?
    private var embeddings: MLModel?
    private var head: MLModel?
    private var prefill: MLModel?
    private var tokenizer: (any Tokenizer)?
    private var state: MLState?
    private var processed: [Int] = []
    private var nextToken: Int?
    private var ids: MLMultiArray?
    private var positions: MLMultiArray?
    private var mask: MLMultiArray?
    private let contextLength = 512

    public init() {}

    public func load(from directory: URL) async throws {
        guard model == nil else { return }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path)
        else { throw ModelFailure.missingFiles }
        let localTokenizer = try await AutoTokenizer.from(modelFolder: directory)
        try Task.checkCancellation()
        func loadPart(_ name: String, function: String? = nil) throws -> MLModel {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            config.functionName = function
            let url = directory.appendingPathComponent(name + ".mlmodelc")
            guard FileManager.default.fileExists(atPath: url.path) else { throw ModelFailure.missingFiles }
            return try MLModel(contentsOf: url, configuration: config)
        }
        let embeddingModel = try loadPart("qwen_embeddings")
        try Task.checkCancellation()
        let inferModel = try loadPart("qwen_FFN_PF_lut6_chunk_01of01", function: "infer")
        try Task.checkCancellation()
        let prefillModel = try loadPart("qwen_FFN_PF_lut6_chunk_01of01", function: "prefill")
        let headModel = try loadPart("qwen_lm_head_lut6")
        try Task.checkCancellation()
        embeddings = embeddingModel
        prefill = prefillModel
        head = headModel
        let loaded = inferModel
        ids = try MLMultiArray(shape: [1, 1], dataType: .int32)
        positions = try MLMultiArray(shape: [1], dataType: .int32)
        mask = try MLMultiArray(shape: [1, 1, 1, 512], dataType: .float16)
        tokenizer = localTokenizer
        model = loaded
        resetContext()
    }

    public func resetContext() {
        processed.removeAll(keepingCapacity: false)
        nextToken = nil
        state = model?.makeState()
    }

    public func unload() {
        state = nil
        model = nil
        embeddings = nil; head = nil; prefill = nil
        tokenizer = nil
        processed = []
        nextToken = nil
        ids = nil; positions = nil; mask = nil
    }

    public func complete(
        prefix: String, maxTokens: Int,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) throws -> InferenceResult {
        guard let tokenizer, model != nil else { throw ModelFailure.missingFiles }
        let start = ContinuousClock.now
        let budget = min(32, max(1, maxTokens))
        let tokens = Array(tokenizer.encode(text: prefix, addSpecialTokens: false).suffix(contextLength - budget))
        guard !tokens.isEmpty else { throw ModelFailure.emptyContext }
        var common = 0
        while common < min(tokens.count, processed.count), tokens[common] == processed[common] { common += 1 }
        // KV entries after the common prefix are masked until overwritten.
        if common == 0 { resetContext() }
        if common < processed.count {
            processed.removeSubrange(common...)
            nextToken = nil
        }
        if common == tokens.count, nextToken == nil {
            common = max(0, common - 1)
            processed = Array(processed.prefix(common))
        }
        let reused = common
        var predicted = common == tokens.count ? nextToken : nil
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
        if cursor < tokens.count {
            predicted = try predict(tokens[cursor], at: cursor)
            processed.append(tokens[cursor])
            nextToken = predicted
        }
        var generated: [Int] = []
        var publishedWordCount = 0
        var reachedLimit = false
        for step in 0..<budget {
            try Task.checkCancellation()
            guard let token = predicted, ![151643, 151645].contains(token) else { break }
            generated.append(token)
            let text = tokenizer.decode(tokens: generated)
            if text.contains("\n") { break }
            // UTF-8 token fragments are decoded together; never publish broken Cyrillic.
            let display = CompletionText.finished(text, reachedLimit: true)
            let wordCount = display.split(whereSeparator: \.isWhitespace).count
            if !text.contains("�"), wordCount > publishedWordCount {
                onPartial?(display)
                publishedWordCount = wordCount
            }
            reachedLimit = step + 1 == budget
            if step + 1 < budget {
                predicted = try predict(token, at: processed.count)
                processed.append(token)
                nextToken = predicted
            }
        }
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        return InferenceResult(text: CompletionText.finished(tokenizer.decode(tokens: generated), reachedLimit: reachedLimit),
                               tokenCount: generated.count, milliseconds: milliseconds, reusedTokens: reused)
    }

    private func predict(_ token: Int, at position: Int) throws -> Int {
        guard position < contextLength, let model, let state,
              let ids, let positions, let mask else { throw ModelFailure.incompatibleModel }
        ids[0] = NSNumber(value: token)
        positions[0] = NSNumber(value: position)
        let maskValues = mask.dataPointer.bindMemory(to: Float16.self, capacity: contextLength)
        for i in 0..<contextLength {
            maskValues[i] = i <= position ? 0 : -Float16.infinity
        }
        guard let embeddings, let head else { throw ModelFailure.missingFiles }
        let embedded = try embeddings.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids)
        ]))
        guard let hidden = embedded.featureValue(for: "hidden_states") else { throw ModelFailure.incompatibleModel }
        let ffnInput = try MLDictionaryFeatureProvider(dictionary: [
            "hidden_states": hidden,
            "position_ids": MLFeatureValue(multiArray: positions),
            "current_pos": MLFeatureValue(multiArray: positions),
            "causal_mask": MLFeatureValue(multiArray: mask)
        ])
        let output = try model.prediction(from: ffnInput, using: state)
        guard let features = output.featureValue(for: "output_hidden_states") else { throw ModelFailure.incompatibleModel }
        let logits = try head.prediction(from: MLDictionaryFeatureProvider(dictionary: ["hidden_states": features]))
        var best: Float16 = -.infinity
        var bestID = 0
        var offset = 0
        for part in 1...16 {
            guard let array = logits.featureValue(for: "logits\(part)")?.multiArrayValue,
                  array.dataType == .float16, array.strides.last?.intValue == 1 else { throw ModelFailure.incompatibleModel }
            let values = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            for i in 0..<array.count where values[i] > best {
                best = values[i]
                bestID = offset + i
            }
            offset += array.count
        }
        return bestID
    }

    private func prefillTokens(_ tokens: [Int], at position: Int) throws {
        guard let embeddings, let prefill, let state else { throw ModelFailure.missingFiles }
        let batch = 64
        let ids = try MLMultiArray(shape: [1, 64], dataType: .int32)
        let positions = try MLMultiArray(shape: [64], dataType: .int32)
        let current = try MLMultiArray(shape: [1], dataType: .int32)
        current[0] = NSNumber(value: position)
        let mask = try MLMultiArray(shape: [1, 1, 64, 512], dataType: .float16)
        let values = mask.dataPointer.bindMemory(to: Float16.self, capacity: batch * contextLength)
        for row in 0..<batch {
            ids[row] = NSNumber(value: row < tokens.count ? tokens[row] : 0)
            positions[row] = NSNumber(value: position + row)
            for col in 0..<contextLength {
                values[row * contextLength + col] = col <= position + row ? 0 : -Float16.infinity
            }
        }
        let embedded = try embeddings.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids)
        ]))
        guard let hidden = embedded.featureValue(for: "hidden_states") else { throw ModelFailure.incompatibleModel }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "hidden_states": hidden, "position_ids": MLFeatureValue(multiArray: positions),
            "current_pos": MLFeatureValue(multiArray: current), "causal_mask": MLFeatureValue(multiArray: mask)
        ])
        _ = try prefill.prediction(from: input, using: state)
    }
}
