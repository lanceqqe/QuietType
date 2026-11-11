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
var screen = ""
var lead = ""
var chat = true
// `--no-ane` exercises the fallback used when Core ML rejects the model on the Neural Engine.
var neuralEngine = true
if arguments.first == "--no-ane" { neuralEngine = false; arguments.removeFirst() }
if arguments.first == "--raw" { chat = false; arguments.removeFirst() }
while let option = arguments.first, ["--model", "--floors", "--memory", "--screen", "--lead"].contains(option), arguments.count >= 2 {
    if option == "--memory" {
        // A file of the user's phrases, one per line: the style sample put before the text.
        memory = try String(contentsOfFile: arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    } else if option == "--screen" {
        // A file with the text visible above the field (a conversation, a letter).
        screen = try String(contentsOfFile: arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    } else if option == "--lead" {
        // A file put verbatim in front of the text, for trying prompt wordings.
        lead = try String(contentsOfFile: arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    } else if option == "--model" {
        directory = URL(fileURLWithPath: arguments[1])
    } else {
        let floors = arguments[1].split(separator: ",").compactMap { Float($0) }
        guard floors.count >= 3 else { fatalError("--floors expects first,word,inner[,freeWords]") }
        profile = DecodingProfile(firstFloor: floors[0], wordFloor: floors[1], innerFloor: floors[2],
                                  freeWords: floors.count > 3 ? Int(floors[3]) : ModelAssets.profile.freeWords)
    }
    arguments.removeFirst(2)
}
if let path = arguments.first, !path.hasPrefix("--") { directory = URL(fileURLWithPath: path) }
if lead.isEmpty { lead = CompletionPrompt.lead(style: memory, screen: screen) }
if arguments.first == "--no-lead" { lead = ""; arguments.removeFirst() }
let model = LocalModel()
let start = ContinuousClock.now
try await model.load(from: directory, profile: profile, neuralEngine: neuralEngine)
print("Loaded \(directory.lastPathComponent) in \(start.duration(to: .now)); compute units: \(await model.computeUnits)")
if arguments.first == "--score" {
    // Teacher-forced check on text files: how often the model's best guess is the next token.
    for path in arguments.dropFirst() {
        let started = ContinuousClock.now
        let result = try await model.score(try String(contentsOfFile: path, encoding: .utf8), lead: lead, chat: chat)
        let elapsed = started.duration(to: .now)
        let ms = (Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15) / Double(result.tokens)
        print("\(path): \(result.tokens) tokens, top-1 \(result.top1), \(ms) ms/token")
    }
    exit(0)
}
if arguments.first == "--eval" {
    // Types every line of the files word by word and checks what the model offers against
    // what was actually written next: how often it speaks up, and how often it is right.
    func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }
    struct Tally { var positions = 0, shown = 0, first = 0, matched = 0, offered = 0, whole = 0; var ms = 0.0 }
    var tallies = ["after a word": Tally(), "inside a word": Tally()]
    var byIndex = [(right: Int, total: Int)](repeating: (0, 0), count: 12)
    let verbose = arguments.contains("--verbose")
    for path in arguments.dropFirst() where !path.hasPrefix("--") {
        for line in try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ").map(String.init)
            for k in 1..<parts.count {
                let head = parts[..<k].joined(separator: " ")
                var cases = [("after a word", head + " ", parts[k...].joined(separator: " "))]
                if parts[k].count >= 6 {
                    cases.append(("inside a word", head + " " + parts[k].prefix(3), String(parts[k].dropFirst(3)) + " " + parts[(k + 1)...].joined(separator: " ")))
                }
                for (kind, prefix, rest) in cases {
                    let result = try await model.complete(prefix: prefix, lead: lead, chat: chat, maxTokens: 40, maxWords: 10)
                    var tally = tallies[kind]!
                    tally.positions += 1; tally.ms += result.milliseconds
                    // Inside a word the fragments are compared glued to what was typed.
                    let glue = kind == "inside a word" ? String(parts[k].prefix(3)) : ""
                    let offered = words(glue + result.text), truth = words(glue + rest)
                    if !result.text.isEmpty {
                        tally.shown += 1
                        var right = 0
                        while right < min(offered.count, truth.count), offered[right] == truth[right] { right += 1 }
                        if right > 0 { tally.first += 1 }
                        if right == offered.count { tally.whole += 1 }
                        tally.matched += right; tally.offered += offered.count
                        for index in 0..<min(offered.count, 12) where index <= right {
                            byIndex[index].total += 1
                            if index < right { byIndex[index].right += 1 }
                        }
                        if verbose { print("\(right)/\(offered.count) \(prefix.suffix(40))│\(result.text)│ ← \(rest.prefix(40))") }
                    }
                    tallies[kind] = tally
                }
            }
        }
    }
    for (kind, t) in tallies.sorted(by: { $0.key < $1.key }) where t.positions > 0 {
        let pct = { (a: Int, b: Int) in b == 0 ? "–" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }
        print("\(kind): \(t.positions) positions, shown \(pct(t.shown, t.positions)), first word right \(pct(t.first, t.shown)), whole right \(pct(t.whole, t.shown)), words right \(t.matched) of \(t.offered) offered, \(Int(t.ms / Double(t.positions))) ms")
    }
    print("right by word index: " + byIndex.filter { $0.total > 0 }.map { "\($0.right)/\($0.total)" }.joined(separator: " "))
    exit(0)
}
if arguments.first == "--try" {
    // Ad-hoc check: complete each given phrase, or keep accepting words with --loop.
    for phrase in arguments.dropFirst() where phrase != "--loop" {
        let result = try await model.complete(prefix: phrase, lead: lead, chat: chat, maxTokens: 28, maxWords: 6)
        print("\(phrase)│\(result.text)│ \(Int(result.milliseconds)) ms / \(result.tokenCount) tokens / reused \(result.reusedTokens)")
        guard arguments.contains("--loop") else { continue }
        var text = phrase
        for _ in 0..<40 {
            let next = try await model.complete(prefix: String(text.suffix(900)), lead: lead, chat: chat, maxTokens: 16).text
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
