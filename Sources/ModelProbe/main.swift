import Foundation
import QuietTypeCore

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--install" {
    arguments.removeFirst()
    let source = URL(fileURLWithPath: arguments.first ?? ".model-cache/anemll")
    try await ModelStore().install(from: source) { file, progress in
        print("\(Int(progress * 100))% \(file)")
    }
    print("Installed at \(ModelAssets.directory.path)")
}
let directory = arguments.first.map { URL(fileURLWithPath: $0) } ?? ModelAssets.directory
let model = LocalModel()
let start = ContinuousClock.now
try await model.load(from: directory)
print("Loaded in \(start.duration(to: .now)); compute units: CPU + Neural Engine")
for prefix in ["Привет! Хотел бы обсудить с тобой", "Спасибо за письмо. Мы свяжемся с вами", "Thank you for your message. I will", "Давай встретимся завтра и обсудим"] {
    let result = try await model.complete(prefix: prefix, maxTokens: 12)
    print("\(prefix) → \(result.text) | \(Int(result.milliseconds)) ms / \(result.tokenCount) tokens")
    let warm = try await model.complete(prefix: prefix + CompletionText.nextWord(result.text), maxTokens: 8)
    print("  warm: \(warm.text) | \(Int(warm.milliseconds)) ms / reused \(warm.reusedTokens)")
    await model.resetContext()
    let cold = try await model.complete(prefix: prefix + CompletionText.nextWord(result.text), maxTokens: 8)
    guard warm.text == cold.text else {
        throw NSError(domain: "ModelProbe.CacheMismatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Warm and cold generation differ: \(warm.text) / \(cold.text)"])
    }
}
