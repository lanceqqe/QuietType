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
    #expect(EnergyPolicy(mode: .economy, lowPower: false, thermal: .nominal).debounceMilliseconds >= 600)
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
