import Foundation
import QuietTypeCore

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--install" {
    arguments.removeFirst()
    let source = URL(fileURLWithPath: arguments.first ?? ".model-cache/gemma1b")
    try await ModelStore().install(from: source) { file, progress in
        print("\(Int(progress * 100))% \(file)")
    }
    print("Installed at \(ModelAssets.directory.path)")
}
// Options before --try: `--model <dir>` probes another ANEMLL model directory,
// `--floors first,word,inner` overrides the confidence floors while calibrating.
var directory = ModelAssets.directory
var profile = ModelAssets.profile
var memory = ""
// `--no-ane` exercises the fallback used when Core ML rejects the model on the Neural Engine.
var neuralEngine = true
if arguments.first == "--no-ane" { neuralEngine = false; arguments.removeFirst() }
while let option = arguments.first, ["--model", "--floors", "--memory"].contains(option), arguments.count >= 2 {
    if option == "--memory" {
        // A file of the user's phrases, one per line: the style sample put before the text.
        memory = try String(contentsOfFile: arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    } else if option == "--model" {
        directory = URL(fileURLWithPath: arguments[1])
    } else {
        let floors = arguments[1].split(separator: ",").compactMap { Float($0) }
        guard floors.count == 3 else { fatalError("--floors expects three numbers") }
        profile = DecodingProfile(firstFloor: floors[0], wordFloor: floors[1], innerFloor: floors[2])
    }
    arguments.removeFirst(2)
}
if let path = arguments.first, !path.hasPrefix("--") { directory = URL(fileURLWithPath: path) }
let model = LocalModel()
let start = ContinuousClock.now
try await model.load(from: directory, profile: profile, neuralEngine: neuralEngine)
print("Loaded \(directory.lastPathComponent) in \(start.duration(to: .now)); compute units: \(await model.computeUnits)")
if arguments.first == "--try" {
    // Ad-hoc check: complete each given phrase, or keep accepting words with --loop.
    for phrase in arguments.dropFirst() where phrase != "--loop" {
        let result = try await model.complete(prefix: phrase, memory: memory, maxTokens: 16)
        print("\(phrase)│\(result.text)│ \(Int(result.milliseconds)) ms / \(result.tokenCount) tokens / reused \(result.reusedTokens)")
        guard arguments.contains("--loop") else { continue }
        var text = phrase
        for _ in 0..<40 {
            let next = try await model.complete(prefix: String(text.suffix(900)), memory: memory, maxTokens: 16).text
            if next.isEmpty { break }
            text += next
        }
        print("  loop: \(text)")
    }
    exit(0)
}
// The last prefix is longer than one 64-token prefill batch, so batched and
// token-by-token KV writes are compared as well.
let long = "Добрый день, коллеги! Вчера на встрече мы договорились, что до конца недели каждый отдел пришлёт свои предложения по бюджету на следующий квартал. Пока я получил документы только от отдела продаж и от бухгалтерии. Остальных прошу не затягивать, потому что в понедельник мне нужно показать сводную таблицу руководству. Если у кого-то остались вопросы по формату, напишите мне сегодня, и я"
for prefix in ["Привет! Хотел бы обсудить с тобой", "Спасибо за письмо. Мы свяжемся с вами", "Thank you for your message. I will", "Давай встретимся завтра и обсудим", long] {
    let result = try await model.complete(prefix: prefix, maxTokens: 12)
    guard result.text.split(whereSeparator: \.isWhitespace).count <= 3 else {
        throw NSError(domain: "ModelProbe.WordLimit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected a completion of at most three words"])
    }
    print("\(prefix) → \(result.text) | \(Int(result.milliseconds)) ms / \(result.tokenCount) tokens")
    let warm = try await model.complete(prefix: prefix + CompletionText.nextWord(result.text), maxTokens: 8)
    print("  warm: \(warm.text) | \(Int(warm.milliseconds)) ms / reused \(warm.reusedTokens)")
    await model.resetContext()
    let cold = try await model.complete(prefix: prefix + CompletionText.nextWord(result.text), maxTokens: 8)
    guard warm.text == cold.text else {
        throw NSError(domain: "ModelProbe.CacheMismatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Warm and cold generation differ: \(warm.text) / \(cold.text)"])
    }
}
