import Testing
import Foundation
import AppKit
@testable import QuietTypeCore

@Test func acceptsRussianWordWithoutBreakingSpacing() {
    #expect(CompletionText.nextWord(" продолжить работу над проектом") == " продолжить")
    #expect(CompletionText.nextWord("вет, как дела?") == "вет,")
}

@Test func utf16ContextPreservesEmojiAndCyrillic() {
    let text = "Привет 👋 мир"
    #expect(CompletionText.prefix(text, utf16Offset: 10) == "Привет 👋 ")
    #expect(CompletionText.prefix(text, utf16Offset: 8) == nil)
    #expect(CompletionText.prefix(text, utf16Offset: -1) == nil)
}

@Test func energyPoliciesBoundWork() {
    #expect(EnergyPolicy(mode: .automatic, lowPower: true, thermal: .nominal).maxTokens == 8)
    #expect(EnergyPolicy(mode: .responsive, lowPower: false, thermal: .critical).allowsAutomatic == false)
    let economy = EnergyPolicy(mode: .economy, lowPower: false, thermal: .nominal)
    let normal = EnergyPolicy(mode: .automatic, lowPower: false, thermal: .nominal)
    #expect(economy.debounceMilliseconds > normal.debounceMilliseconds)
    #expect(normal.debounceMilliseconds <= 150)
    #expect(EnergyPolicy(mode: .responsive, lowPower: false, thermal: .nominal).debounceMilliseconds < normal.debounceMilliseconds)
}

@Test func rejectsSecretsAndSecureApplications() {
    #expect(PrivacyGate.isExcluded(bundleID: "com.agilebits.onepassword7", custom: []))
    #expect(PrivacyGate.isExcluded(bundleID: "com.apple.Terminal", custom: []))
    #expect(!PrivacyGate.isExcluded(bundleID: "com.apple.TextEdit", custom: []))
    #expect(!PrivacyGate.allowsContext("token = sk-abcdefghijklmnopqrstuvwx"))
    #expect(PrivacyGate.allowsContext("Давай обсудим проект завтра"))
}

@Test func cacheIsBoundedAndDoesNotSurviveClear() {
    var cache = CompletionCache(capacity: 2)
    cache.insert(" один", for: "первый")
    cache.insert(" два", for: "второй")
    cache.insert(" три", for: "третий")
    #expect(cache.value(for: "первый") == nil)
    #expect(cache.value(for: "третий") == " три")
    cache.clear()
    #expect(cache.value(for: "третий") == nil)
}

@Test func doesNotOfferTruncatedWordsAtTokenLimit() {
    #expect(CompletionText.finished(" продолжить обсуждение проек", reachedLimit: true) == " продолжить обсуждение")
    #expect(CompletionText.finished("вет", reachedLimit: true) == "")
    #expect(CompletionText.finished(" Спасибо!", reachedLimit: true) == " Спасибо!")
    #expect(CompletionText.finished(" мир", reachedLimit: false) == " мир")
}

@Test func doesNotPublishControlTokensOrBrokenUTF8() {
    #expect(CompletionText.clean("<|im_end|>") == "")
    #expect(CompletionText.clean("ошиб�") == "")
    #expect(CompletionText.clean(" текст\nСледующая строка") == " текст")
}

@Test func excludesApplicationFamiliesAndCustomIDs() {
    #expect(PrivacyGate.isExcluded(bundleID: "com.1password.1password", custom: []))
    #expect(PrivacyGate.isExcluded(bundleID: "com.apple.mail", custom: ["com.apple.mail"]))
    #expect(!PrivacyGate.isExcluded(bundleID: "com.apple.mail.other", custom: ["com.apple.mail2"]))
}

@Test func readsActualAXFontInsteadOfGuessingFromCaretHeight() {
    let style = HostTextStyle(attributes: [NSAttributedString.Key("AXFont"):
        ["AXFontName": "Helvetica", "AXFontSize": NSNumber(value: 17)]], caretHeight: 12)
    #expect(style.font.pointSize == 17)
    #expect(style.font.familyName == "Helvetica")
}

@Test func preservesNativeAttributedFont() {
    let style = HostTextStyle(attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)], caretHeight: 20)
    #expect(style.font.pointSize == 14)
}

@Test func observesEmptyEditableFieldsBeforeThereIsEnoughTextToGenerate() {
    #expect(TextFieldPolicy.shouldObserve(role: "AXTextArea", subrole: nil, protected: false))
    #expect(!TextFieldPolicy.mayGenerate(selectionLength: 0, prefixCount: 0))
    #expect(TextFieldPolicy.mayGenerate(selectionLength: 0, prefixCount: 3))
    #expect(!TextFieldPolicy.mayGenerate(selectionLength: 2, prefixCount: 20))
}

@Test func neverObservesPasswordFields() {
    #expect(!TextFieldPolicy.shouldObserve(role: "AXTextField", subrole: "AXSecureTextField", protected: false))
    #expect(!TextFieldPolicy.shouldObserve(role: "AXTextArea", subrole: nil, protected: true))
    #expect(!TextFieldPolicy.shouldObserve(role: "AXButton", subrole: nil, protected: false))
}

@Test func defaultSuggestionHasAtMostThreeWords() {
    #expect(CompletionText.firstWords(" обсудить проект завтра утром", count: 3) == " обсудить проект завтра")
    #expect(CompletionText.firstWords(" review the project tomorrow", count: 3) == " review the project")
    #expect(CompletionText.firstWords("вет, как дела? Хорошо", count: 3) == "вет, как дела?")
    #expect(CompletionText.firstWords(" два слова", count: 3) == " два слова")
    #expect(CompletionText.firstWords(" текст", count: 0) == "")
}

@Test func repredictsTheWordUnderTheCaret() {
    let midWord = CompletionText.healingSplit("Давай обсуд")
    #expect(midWord?.stable == "Давай" && midWord?.target == " обсуд")
    let afterSpace = CompletionText.healingSplit("Давай ")
    #expect(afterSpace?.stable == "Давай" && afterSpace?.target == " ")
    #expect(CompletionText.healingSplit("Привет") == nil)
    #expect(CompletionText.healingSplit("Строка\nслово") == nil)
    #expect(CompletionText.healingSplit("Два  ") == nil)
}

@Test func contextWindowStartStaysPutWhileTyping() {
    let text = String(repeating: "слово и ещё ", count: 200)
    func window(_ location: Int) -> String {
        let end = String.Index(utf16Offset: location, in: text)
        let fetched = String(text[..<end].suffix(1024))
        return CompletionText.stableContext(fetched, location: location, minimum: 900, chunk: 300)
    }
    let first = window(1501), second = window(1502), later = window(1790)
    #expect(second.hasPrefix(first))
    #expect(later.hasPrefix(first))
    #expect(first.count > 500 && later.count <= 900)
    #expect(first.first?.isWhitespace == false)
    #expect(window(1801).count < later.count - 200)
    #expect(CompletionText.stableContext("короткий текст", location: 14, minimum: 900, chunk: 300) == "короткий текст")
    #expect(!CompletionText.stableContext(String(repeating: "👋", count: 600), location: 1200, minimum: 900, chunk: 301).isEmpty)
}

@Test func typedBufferFollowsKeysAndForgetsWhenTheCaretMayHaveMoved() {
    var buffer = TypedBuffer()
    for character in "Привет мир" {
        buffer.apply(TypedBuffer.key(keyCode: 0, command: false, control: false, option: false, characters: String(character)))
    }
    #expect(buffer.text == "Привет мир")
    buffer.apply(TypedBuffer.key(keyCode: 51, command: false, control: false, option: false, characters: "\u{7F}"))
    #expect(buffer.text == "Привет ми")
    buffer.apply(TypedBuffer.key(keyCode: 51, command: false, control: false, option: true, characters: ""))
    #expect(buffer.text == "Привет ")
    #expect(TypedBuffer.key(keyCode: 123, command: false, control: false, option: false, characters: "\u{F702}") == .reset)
    #expect(TypedBuffer.key(keyCode: 36, command: false, control: false, option: false, characters: "\r") == .reset)
    #expect(TypedBuffer.key(keyCode: 9, command: true, control: false, option: false, characters: "v") == .reset)
    buffer.apply(.reset)
    #expect(buffer.text.isEmpty)
}

@Test func keystrokeFallbackIsLimitedToKnownApps() {
    // Telegram exposes its message field; it only misreports the caret line.
    #expect(!KeystrokeFallback.applies(bundleID: "ru.keepcoder.Telegram"))
    #expect(!KeystrokeFallback.applies(bundleID: "com.apple.finder"))
}

@Test func styleMemoryRecallsHabitualPhrases() {
    var memory = StyleMemory()
    for _ in 0..<3 { memory.learn("ща гляну и отпишусь", app: "tg") }
    #expect(memory.continuation(of: "ок, ща гляну ") == "и отпишусь")
    #expect(memory.continuation(of: "ща гляну и отп") == "ишусь")
    // Seen once: not a habit yet.
    var fresh = StyleMemory()
    fresh.learn("ща гляну и отпишусь", app: "tg")
    #expect(fresh.continuation(of: "ща гляну ") == nil)
    // A habit does not cross a sentence boundary.
    #expect(memory.continuation(of: "ща гляну. ") == nil)
}

@Test func styleMemoryCompletesPersonalVocabulary() {
    var memory = StyleMemory()
    for _ in 0..<4 { memory.learn("созвон по Квайеттайпу", app: "tg") }
    #expect(memory.continuation(of: "что там с Квай") == "еттайпу")
    #expect(memory.continuation(of: "Кв") == nil)
}

@Test func styleMemorySkipsSecretsAndNumbers() {
    var memory = StyleMemory()
    memory.learn("password: hunter22 и ещё слова", app: "tg")
    #expect(memory.isEmpty)
    memory.learn("код 483920 пришёл на почту vasya@example.com", app: "tg")
    #expect(memory.samples.isEmpty)
    #expect(memory.words["483920"] == nil && memory.words.keys.allSatisfy { !$0.contains("@") })
}

@Test func styleCardPrefersTheCurrentAppAndFitsTheLimit() {
    var memory = StyleMemory()
    memory.learn("давай созвонимся завтра утром", app: "mail")
    memory.learn("го в пятницу на падел", app: "tg")
    memory.learn("норм, закину правки вечером", app: "tg")
    #expect(memory.styleCard(app: "tg", limit: 60) == "го в пятницу на падел\nнорм, закину правки вечером")
    #expect(memory.styleCard(app: "tg").hasPrefix("давай созвонимся"))
}

@Test func versionComparisonIsNumeric() {
    #expect(AppVersion.isNewer("0.10.0", than: "0.9.3"))
    #expect(AppVersion.isNewer("0.2.1", than: "0.2"))
    #expect(!AppVersion.isNewer("0.2.0", than: "0.2"))
    #expect(!AppVersion.isNewer("0.1.9", than: "0.2.0"))
    #expect(!AppVersion.isNewer("latest", than: "0.2.0"))
}

@Test func screenTextKeepsTheConversationAboveTheField() {
    let field = CGRect(x: 300, y: 800, width: 600, height: 40)
    func piece(_ text: String, _ x: CGFloat, _ y: CGFloat) -> ScreenText.Fragment {
        .init(text: text, frame: CGRect(x: x, y: y, width: 200, height: 18))
    }
    let text = ScreenText.assemble([
        piece("мангал", 520, 700), piece("с тебя уголь и", 310, 701),   // one row, out of order
        piece("ты в субботу свободен?", 310, 660),
        piece("Список чатов", 20, 660),                                  // sidebar, another column
        piece("Отправить", 310, 850),                                    // below the field
    ], field: field)
    #expect(text == "ты в субботу свободен?\nс тебя уголь и мангал")
}

@Test func screenTextIsCutToTheLinesNearestTheField() {
    let field = CGRect(x: 0, y: 5_000, width: 600, height: 40)
    let fragments = (0..<50).map { ScreenText.Fragment(text: "строка номер \($0)", frame: CGRect(x: 10, y: CGFloat($0) * 20, width: 200, height: 18)) }
    let text = ScreenText.assemble(fragments, field: field, limit: 100)
    #expect(text.count <= 100 && text.hasSuffix("строка номер 49") && text.hasPrefix("строка номер"))
    #expect(ScreenText.assemble([.init(text: "password: hunter22", frame: CGRect(x: 10, y: 10, width: 100, height: 18))], field: field).isEmpty)
}
