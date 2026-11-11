import Foundation

/// The request put in front of the field's text. The model is instruction-tuned: told what
/// it is doing, it continues the user's message instead of carrying on whatever it was shown
/// (a chat above the field, with its timestamps and buttons).
public enum CompletionPrompt {
    /// `style` is a sample of the user's own phrases, `screen` the text visible above the
    /// field. The style sample comes first: it changes rarely, so the model keeps its cache
    /// of it while the screen text is replaced.
    public static func lead(style: String = "", screen: String = "") -> String {
        // Two wordings, each the best of those measured for its case: with screen text the
        // model has to be kept in the user's role, without it a plain request leaks least.
        var text = screen.isEmpty
            ? "Пользователь начал писать сообщение. Допиши его так, как написал бы он сам: тем же языком и тоном. Выведи сообщение целиком, без пояснений."
            : "Ты — автодополнение. Пользователь печатает сообщение, продолжи его естественно, от его лица, на том же языке. Не повторяй время, числа и элементы интерфейса с экрана."
        if !style.isEmpty { text += "\n\nТак пользователь обычно пишет:\n" + plain(style) }
        if !screen.isEmpty { text += "\n\nЧто пользователь видит на экране:\n" + plain(screen) + "\n\nПродолжи его сообщение." }
        return text
    }

    /// Text from outside must not be able to close the request and start a turn of its own.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<start_of_turn>", with: "").replacingOccurrences(of: "<end_of_turn>", with: "")
    }
}
