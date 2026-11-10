import AppKit
import ApplicationServices
import QuietTypeCore

@MainActor
final class TypingService {
    private struct Field {
        let element: AXUIElement
        let pid: pid_t
        let selection: CFRange
        let prefix: String
        let caret: CGRect
        let container: CGRect
        let font: NSFont
        let color: NSColor

        func matches(_ other: Field) -> Bool {
            pid == other.pid && CFEqual(element, other.element) &&
            selection.location == other.selection.location && selection.length == other.selection.length && prefix == other.prefix
        }
    }

    private let state: AppState
    private let panel = SuggestionPanel()
    private var observer: AXObserver?
    private var observedRoot: AXUIElement?
    private var observedField: AXUIElement?
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var activationToken: NSObjectProtocol?
    private var powerToken: NSObjectProtocol?
    private var thermalToken: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var requestID = UUID()
    private var current: Field?
    private var suggestion = ""
    private var cache = CompletionCache()
    private var acceptedContinuation: (field: Field, inserted: String, remainder: String)?
    private let syntheticEventTag: Int64 = 0x51545950

    init(state: AppState) { self.state = state }

    func start() {
        state.onPause = { [weak self] in self?.clearContext() }
        state.onPermissionsChanged = { [weak self] in self?.refresh() }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.attachToFrontmost() } }
        powerToken = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.clearContext() }
        }
        thermalToken = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.clearContext() }
        }
        refresh()
    }

    func refresh() {
        state.accessibilityGranted = AXIsProcessTrusted()
        if state.accessibilityGranted { installEventTap(); attachToFrontmost() }
    }

    func requestKeyboardAccess() {
        _ = CGRequestListenEventAccess()
        installEventTap()
        if !state.keyboardGranted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    private func installEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            state.keyboardGranted = true
            return
        }
        guard state.accessibilityGranted else { return }
        let watchedEvents: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        let eventMask = watchedEvents.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                   eventsOfInterest: eventMask,
                                   callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let consumed = MainActor.assumeIsolated {
                let service = Unmanaged<TypingService>.fromOpaque(info).takeUnretainedValue()
                return service.handle(type: type, event: event)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { state.keyboardGranted = false; return }
        eventTap = tap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let tapSource { CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        state.keyboardGranted = true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .leftMouseDown || type == .rightMouseDown || type == .scrollWheel {
            acceptedContinuation = nil
            dismiss()
            return false
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            dismiss()
            return false
        }
        guard type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != syntheticEventTag else {
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if key == 49, flags == [.maskControl, .maskAlternate] {
            schedule(manual: true)
            return false
        }
        if key == 48, (flags.isEmpty || flags == .maskAlternate), !suggestion.isEmpty,
           accept(all: flags == .maskAlternate) { return true }
        if key == 53, !suggestion.isEmpty {
            acceptedContinuation = nil
            dismiss()
            return true
        }
        // Dismiss before the host processes a key, so Tab can never take an old suggestion.
        acceptedContinuation = nil
        dismiss()
        return false
    }

    private func attachToFrontmost() {
        clearContext()
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; observedRoot = nil; observedField = nil
        guard state.accessibilityGranted, let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = application.bundleIdentifier,
              !PrivacyGate.isExcluded(bundleID: bundleID, custom: state.exclusions) else {
            state.activeApplication = "Нет текстового поля"
            return
        }
        state.activeApplication = application.localizedName ?? bundleID
        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.08)
        var created: AXObserver?
        let result = AXObserverCreate(application.processIdentifier, { _, _, notification, pointer in
            guard let pointer else { return }
            MainActor.assumeIsolated {
                let service = Unmanaged<TypingService>.fromOpaque(pointer).takeUnretainedValue()
                if notification as String == kAXFocusedUIElementChangedNotification { service.observeFocus() }
                else { service.schedule(manual: false) }
            }
        }, &created)
        guard result == .success, let created else { return }
        observer = created; observedRoot = root
        AXObserverAddNotification(created, root, kAXFocusedUIElementChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observeFocus()
    }

    private func observeFocus() {
        clearContext()
        if let observer, let field = observedField {
            for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
                AXObserverRemoveNotification(observer, field, name as CFString)
            }
        }
        observedField = nil
        guard let observer, let field = readField() else { return }
        observedField = field.element
        for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(observer, field.element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        schedule(manual: false)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func readField() -> Field? {
        state.fieldStatus = "Ожидание доступного поля ввода"
        guard state.enabled, state.accessibilityGranted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundle = app.bundleIdentifier,
              !PrivacyGate.isExcluded(bundleID: bundle, custom: state.exclusions) else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.08)
        guard let focused = attribute(root, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let field = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(field, 0.03)
        let role = attribute(field, kAXRoleAttribute) as? String
        let subrole = attribute(field, kAXSubroleAttribute) as? String
        state.fieldStatus = "Проверка поля: \(role ?? "нет типа")"
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? ""),
              subrole != kAXSecureTextFieldSubrole,
              (attribute(field, "AXProtectedContent") as? Bool) != true,
              let rawRange = attribute(field, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(rawRange, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var selection = CFRange()
        state.fieldStatus = "Ожидание текста перед курсором"
        guard AXValueGetValue(rangeValue, .cfRange, &selection), selection.length == 0, selection.location >= 3 else { return nil }
        // Inline continuation is eligible only at the end of existing text.
        // Otherwise ghost glyphs would cover real words already in the document.
        if let count = attribute(field, kAXNumberOfCharactersAttribute) as? Int, count > selection.location {
            var tailRange = CFRange(location: selection.location, length: min(128, count - selection.location))
            if let value = AXValueCreate(.cfRange, &tailRange) {
                var tail: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, value, &tail) == .success,
                   let text = tail as? String, !text.allSatisfy(\.isWhitespace) {
                    state.fieldStatus = "Переместите курсор в конец текста для подсказки"
                    return nil
                }
            }
        }
        var contextRange = CFRange(location: max(0, selection.location - 1024), length: min(1024, selection.location))
        guard let parameter = AXValueCreate(.cfRange, &contextRange) else { return nil }
        var rawText: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, parameter, &rawText)
        let prefix: String
        if result == .success, let text = rawText as? String { prefix = text }
        else {
            // Bound the fallback before fetching an entire document.
            guard let count = attribute(field, kAXNumberOfCharactersAttribute) as? Int, count <= 32_768,
                  let text = attribute(field, kAXValueAttribute) as? String,
                  let before = CompletionText.prefix(text, utf16Offset: selection.location) else { return nil }
            prefix = String(before.suffix(state.policy.contextCharacters))
        }
        let bounded = String(prefix.suffix(state.policy.contextCharacters))
        state.fieldStatus = "Проверка контекста и координат"
        guard bounded.count >= 3, PrivacyGate.allowsContext(bounded) else { return nil }
        var caretRange = selection
        guard let caretParameter = AXValueCreate(.cfRange, &caretRange) else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                        caretParameter, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var caret = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(bounds, to: AXValue.self), .cgRect, &caret),
              caret.height > 0, caret.origin.x.isFinite, caret.origin.y.isFinite else { return nil }
        caret.origin.y = (NSScreen.screens.first?.frame.maxY ?? 0) - caret.maxY
        var container = caret.insetBy(dx: -220, dy: -80)
        if let positionValue = attribute(field, kAXPositionAttribute), CFGetTypeID(positionValue) == AXValueGetTypeID(),
           let sizeValue = attribute(field, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            var position = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
               AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size), size.width > 0 {
                container = CGRect(x: position.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - position.y - size.height,
                                   width: size.width, height: size.height)
            }
        }
        // Use the host's actual text origin, including its text-container inset.
        var lineNumber: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(field, kAXLineForIndexParameterizedAttribute as CFString,
                                                      NSNumber(value: selection.location), &lineNumber) == .success,
           let lineNumber {
            var rawLine: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(field, kAXRangeForLineParameterizedAttribute as CFString,
                                                          lineNumber, &rawLine) == .success,
               let rawLine, CFGetTypeID(rawLine) == AXValueGetTypeID() {
                var line = CFRange()
                if AXValueGetValue(unsafeDowncast(rawLine, to: AXValue.self), .cfRange, &line), line.length > 0 {
                    line.length = 1
                    if let lineValue = AXValueCreate(.cfRange, &line) {
                        var startBounds: CFTypeRef?
                        if AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                                      lineValue, &startBounds) == .success,
                           let startBounds, CFGetTypeID(startBounds) == AXValueGetTypeID() {
                            var firstGlyph = CGRect.zero
                            if AXValueGetValue(unsafeDowncast(startBounds, to: AXValue.self), .cgRect, &firstGlyph),
                               firstGlyph.minX >= container.minX, firstGlyph.minX <= caret.minX {
                                let inset = firstGlyph.minX - container.minX
                                container.origin.x = firstGlyph.minX
                                container.size.width -= inset * 2
                            }
                        }
                    }
                }
            }
        }
        var attributes: [NSAttributedString.Key: Any] = [:]
        var precedingRange = CFRange(location: max(0, selection.location - 1), length: 1)
        var styled: CFTypeRef?
        if let precedingValue = AXValueCreate(.cfRange, &precedingRange),
           AXUIElementCopyParameterizedAttributeValue(field, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                      precedingValue, &styled) == .success,
           let attributed = styled as? NSAttributedString, attributed.length > 0 {
            attributes = attributed.attributes(at: 0, effectiveRange: nil)
        }
        let style = HostTextStyle(attributes: attributes, caretHeight: caret.height)
        guard container.insetBy(dx: -2, dy: -2).contains(CGPoint(x: caret.midX, y: caret.midY)) else {
            state.fieldStatus = "Курсор вне видимой области поля"
            return nil
        }
        state.fieldStatus = "Поле готово · \(Int(style.font.pointSize)) pt · \(bounded.count) символов контекста"
        return Field(element: field, pid: app.processIdentifier, selection: selection, prefix: bounded,
                     caret: caret, container: container, font: style.font, color: style.color)
    }

    private func schedule(manual: Bool) {
        dismiss()
        guard state.enabled, state.modelReady, state.policy.allowsAutomatic,
              !state.manualOnly || manual, let field = readField() else { return }
        current = field
        let id = requestID
        if let continuation = acceptedContinuation {
            let expected = String((continuation.field.prefix + continuation.inserted).suffix(state.policy.contextCharacters))
            if field.pid == continuation.field.pid,
               CFEqual(field.element, continuation.field.element),
               field.selection.location == continuation.field.selection.location + continuation.inserted.utf16.count,
               field.prefix == expected {
                acceptedContinuation = nil
                cache.insert(continuation.remainder, for: field.prefix)
                publish(continuation.remainder, field: field, id: id)
                return
            }
        }
        let policy = state.policy
        pending = Task { [weak self] in
            guard let self else { return }
            do {
                if !manual { try await Task.sleep(for: .milliseconds(policy.debounceMilliseconds)) }
                try Task.checkCancellation()
                guard let now = readField(), field.matches(now) else { return }
                if let cached = cache.value(for: field.prefix) {
                    publish(cached, field: field, id: id)
                    return
                }
                let result = try await state.engine.complete(prefix: field.prefix, maxTokens: policy.maxTokens) { [weak self] partial in
                    Task { @MainActor in self?.publishPartial(partial, id: id) }
                }
                try Task.checkCancellation()
                guard requestID == id else { return }
                cache.insert(result.text, for: field.prefix)
                state.record(result)
                publish(result.text, field: field, id: id)
            } catch is CancellationError {} catch {
                if requestID == id { state.error = error.localizedDescription; dismiss() }
            }
        }
    }

    private func publishPartial(_ text: String, id: UUID) {
        guard requestID == id, let current else { return }
        publish(text, field: current, id: id)
    }

    private func publish(_ text: String, field: Field, id: UUID) {
        guard requestID == id, state.enabled, let now = readField(), field.matches(now), !text.isEmpty else { return }
        current = field
        suggestion = text
        panel.show(text, caret: now.caret, container: now.container, font: now.font, color: now.color)
    }

    private func accept(all: Bool) -> Bool {
        guard state.enabled, state.modelReady, let current, let live = readField(), current.matches(live) else {
            dismiss(); return false
        }
        let text = all ? suggestion : CompletionText.nextWord(suggestion)
        guard !text.isEmpty else { return false }
        let remainder = String(suggestion.dropFirst(text.count))
        dismiss()
        acceptedContinuation = remainder.isEmpty ? nil : (live, text, remainder)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(live.element, kAXSelectedTextAttribute as CFString, &settable)
        if settable.boolValue,
           AXUIElementSetAttributeValue(live.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            var range = CFRange(location: live.selection.location + text.utf16.count, length: 0)
            if let value = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(live.element, kAXSelectedTextRangeAttribute as CFString, value)
            }
        } else {
            // Unicode events preserve the clipboard and work with standard browser fields.
            let characters = Array(text.utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
            for event in [down, up] {
                event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
                event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
                event.postToPid(live.pid)
            }
        }
        state.acceptedCharacters += text.count
        // Direct AX insertion is synchronous: preserve the rest for repeated Tab.
        // Unicode fallback delivers a field-change notification after its events.
        if let after = readField(), after.selection.location == live.selection.location + text.utf16.count {
            schedule(manual: true)
        }
        return true
    }

    private func dismiss() {
        pending?.cancel(); pending = nil
        requestID = UUID()
        current = nil; suggestion = ""
        panel.hide()
    }

    private func clearContext() {
        dismiss()
        acceptedContinuation = nil
        cache.clear()
        Task { await state.engine.resetContext() }
    }
}
