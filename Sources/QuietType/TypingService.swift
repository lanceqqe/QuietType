import AppKit
import ApplicationServices
import Carbon.HIToolbox
import QuietTypeCore

@MainActor
final class TypingService {
    private struct Field {
        let element: AXUIElement?   // nil: the text comes from observed keystrokes
        let pid: pid_t
        let location: Int           // UTF-16 caret offset (or typed length)
        let prefix: String
        let caret: CGRect?          // nil: host gives no caret geometry, use the pill
        let container: CGRect
        let font: NSFont
        let color: NSColor
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
    /// The rest of a suggestion whose beginning was accepted or typed by hand.
    private var acceptedContinuation: (field: Field, inserted: String, remainder: String)?
    /// Hosts that hide their text field from Accessibility are followed by keystrokes.
    private var keystrokeMode = false
    private var typed = TypedBuffer()
    /// Web content often reports AX insertion as successful without performing it.
    private var insertsByTyping = false
    /// What the user typed in the current field since the last caret jump: the only text
    /// the style memory learns from. Pasted and pre-existing text never gets here.
    private var written = TypedBuffer()
    private var frontBundle = ""
    private var styleCard = ""
    /// Text visible above the focused field; memory only, replaced on focus and after a send.
    private var screenContext = ""
    private var screenTask: Task<Void, Never>?
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

    /// Runs inside the event tap, which delays every keystroke on the system while it works.
    /// It therefore only touches local state; Accessibility calls happen in later tasks.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            dismiss()
            return false
        }
        if type == .scrollWheel {
            // The pill is not anchored to the caret, scrolling does not invalidate it.
            if !keystrokeMode, current?.caret != nil { acceptedContinuation = nil; dismiss() }
            return false
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            acceptedContinuation = nil
            typed.apply(.reset)
            commitWritten()
            dismiss()
            if keystrokeMode || observedField == nil {
                // A click may move focus without any Accessibility notification.
                pending = Task { [weak self] in
                    guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
                    self?.observeFocus()
                }
            }
            return false
        }
        guard type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != syntheticEventTag else {
            return false
        }
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if key == 49, flags == [.maskControl, .maskAlternate] {
            schedule(manual: true)
            return false
        }
        // A visible suggestion owns Tab unconditionally: nothing is re-read here, so a slow
        // host (browsers) can neither time the tap out nor receive the key itself.
        if key == 48, flags.isEmpty || flags == .maskAlternate, !suggestion.isEmpty, state.enabled,
           let field = current, NSWorkspace.shared.frontmostApplication?.processIdentifier == field.pid {
            accept(all: flags == .maskAlternate, field: field)
            return true
        }
        if key == 53, !suggestion.isEmpty {
            acceptedContinuation = nil
            dismiss()
            return true
        }
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &units)
        let characters = String(utf16CodeUnits: units, count: length)
        let shortcut = !flags.intersection([.maskCommand, .maskControl]).isEmpty
        let typedKey = TypedBuffer.key(keyCode: key, command: flags.contains(.maskCommand), control: flags.contains(.maskControl),
                                       option: flags.contains(.maskAlternate), characters: characters)
        // Typing the suggested characters keeps the rest of the suggestion: no new inference.
        if case .text(let string) = typedKey, let field = current,
           suggestion.hasPrefix(string), suggestion.count > string.count {
            acceptedContinuation = (field, string, String(suggestion.dropFirst(string.count)))
        } else {
            acceptedContinuation = nil
        }
        // Dismiss before the host processes a key, so Tab can never take an old suggestion.
        dismiss()
        // After a send the conversation on screen has changed.
        if key == 36 || key == 76 { refreshScreen(after: 800) }
        if typedKey == .reset || observedField == nil || IsSecureEventInputEnabled() { commitWritten() }
        else if state.memoryEnabled { written.apply(typedKey) }
        guard state.enabled, state.modelReady else { return false }
        if keystrokeMode {
            // Password prompts turn Secure Input on; never follow keys there.
            typed.apply(IsSecureEventInputEnabled() ? .reset : typedKey)
            if !typed.text.isEmpty { schedule(manual: false) }
        } else if !shortcut {
            // Some custom editors omit AX value notifications. A single cancellable
            // follow-up per key reads the field after the host has handled the event.
            // AX notifications supersede this task when the editor does send them.
            pending = Task { [weak self] in
                guard (try? await Task.sleep(for: .milliseconds(25))) != nil, let self else { return }
                if observedField == nil { observeFocus() }
                else { schedule(manual: false) }
            }
        }
        return false
    }

    private func refreshScreen(after delay: Int) {
        screenTask?.cancel()
        guard state.screenEnabled, state.enabled, let element = observedField,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { screenContext = ""; return }
        nonisolated(unsafe) let field = element
        screenTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(delay))) != nil else { return }
            let started = ContinuousClock.now
            let reading = await ScreenReader.read(element: field, pid: pid, allowCapture: true)
            guard let self else { return }
            guard !Task.isCancelled, let now = observedField, CFEqual(now, field) else {
                state.log("screen: read dropped, focus moved (\(reading.source))")
                return
            }
            if reading.text != screenContext { screenContext = reading.text; cache.clear() }
            let elapsed = started.duration(to: .now).components
            state.log("screen: \(reading.text.count) chars via \(reading.source) in \(Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)) ms")
        }
    }

    /// Hands the finished fragment to the style memory.
    private func commitWritten() {
        let text = written.text
        written.apply(.reset)
        guard state.memoryEnabled, text.count >= 8, !frontBundle.isEmpty else { return }
        state.learn(text, app: frontBundle)
        state.log("memory: learned \(text.count) chars")
    }

    private func attachToFrontmost() {
        clearContext()
        frontBundle = ""; styleCard = ""
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; observedRoot = nil; observedField = nil
        keystrokeMode = false; insertsByTyping = false
        guard state.accessibilityGranted, let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = application.bundleIdentifier,
              !PrivacyGate.isExcluded(bundleID: bundleID, custom: state.exclusions) else {
            state.activeApplication = "Нет текстового поля"
            return
        }
        state.activeApplication = application.localizedName ?? bundleID
        frontBundle = bundleID
        // Fixed while the app stays in front, so the model keeps its cache of it.
        styleCard = state.memoryEnabled ? state.memory.styleCard(app: bundleID) : ""
        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.08)
        // Chromium and Electron build the web Accessibility tree only for assistive clients.
        if AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success,
           ["chrome", "chromium", "brave", "edgemac", "vivaldi", "opera", "yandex", "thebrowser"]
            .contains(where: bundleID.lowercased().contains) {
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
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
        dismiss()
        acceptedContinuation = nil
        cache.clear()
        typed.apply(.reset)
        commitWritten()
        if let observer, let field = observedField {
            for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
                AXObserverRemoveNotification(observer, field, name as CFString)
            }
        }
        observedField = nil
        keystrokeMode = false
        insertsByTyping = false
        screenTask?.cancel(); screenContext = ""
        guard let observer else { return } // No observer: excluded app or no permission.
        guard let target = focusedTarget() else {
            if state.enabled, let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               KeystrokeFallback.applies(bundleID: bundle) {
                keystrokeMode = true
                state.log("keystroke mode on")
                state.fieldStatus = "Приложение скрывает поле ввода: подсказка по набранному тексту"
            }
            return
        }
        observedField = target.element
        for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(observer, target.element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        // Telegram's AXSelectedText setter inserts the text twice; type there instead.
        insertsByTyping = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "ru.keepcoder.Telegram"
        var ancestor = target.element
        for _ in 0..<(insertsByTyping ? 0 : 16) {
            guard let parent = attribute(ancestor, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            ancestor = unsafeDowncast(parent, to: AXUIElement.self)
            if attribute(ancestor, kAXRoleAttribute) as? String == "AXWebArea" { insertsByTyping = true; break }
        }
        refreshScreen(after: 150)
        schedule(manual: false)
    }

    private func rect(_ element: AXUIElement, range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                        parameter, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(bounds, to: AXValue.self), .cgRect, &rect),
              rect.height > 0, rect.height < 400, rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        return rect
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute), CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attribute(element, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(x: position.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - position.y - size.height,
                      width: size.width, height: size.height)
    }

    /// Keystroke mode: the context is what was typed, the anchor is the focused window.
    private func typedField() -> Field? {
        guard state.enabled, !IsSecureEventInputEnabled(), let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier, KeystrokeFallback.applies(bundleID: bundle) else { return nil }
        let policy = state.policy
        let context = CompletionText.stableContext(typed.text, location: typed.text.utf16.count,
                                                   minimum: policy.contextCharacters, chunk: policy.contextCharacters / 3)
        guard context.count >= 3, PrivacyGate.allowsContext(context) else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.05)
        var window = NSScreen.main?.visibleFrame ?? .zero
        if let focused = attribute(root, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(),
           let frame = frame(unsafeDowncast(focused, to: AXUIElement.self)) { window = frame }
        state.fieldStatus = "Подсказка по набранному тексту · \(context.count) символов контекста"
        return Field(element: nil, pid: app.processIdentifier, location: typed.text.utf16.count, prefix: context,
                     caret: nil, container: window, font: .systemFont(ofSize: 13), color: .labelColor)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func focusedTarget() -> (element: AXUIElement, pid: pid_t)? {
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
        state.fieldStatus = "Проверка поля: \(role ?? "нет типа") \(subrole ?? "")"
        guard TextFieldPolicy.shouldObserve(role: role, subrole: subrole,
                                          protected: (attribute(field, "AXProtectedContent") as? Bool) == true) else { return nil }
        state.activeApplication = app.localizedName ?? bundle
        return (field, app.processIdentifier)
    }

    private func readField() -> Field? {
        if keystrokeMode { return typedField() }
        guard let target = focusedTarget() else { return nil }
        let field = target.element
        guard let rawRange = attribute(field, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(rawRange, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var selection = CFRange()
        state.fieldStatus = "Ожидание текста перед курсором"
        guard AXValueGetValue(rangeValue, .cfRange, &selection),
              TextFieldPolicy.mayGenerate(selectionLength: selection.length, prefixCount: selection.location) else { return nil }
        // Inline continuation is eligible only at the end of existing text.
        // Otherwise ghost glyphs would cover real words already in the document.
        if let count = attribute(field, kAXNumberOfCharactersAttribute) as? Int, count > selection.location {
            var tailRange = CFRange(location: selection.location, length: min(128, count - selection.location))
            if let value = AXValueCreate(.cfRange, &tailRange) {
                var tail: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, value, &tail) == .success,
                   let text = tail as? String, !text.allSatisfy(\.isWhitespace) {
                    state.log("text after caret: \(text.count) chars of \(count) total, caret at \(selection.location)")
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
            prefix = String(before.suffix(1024))
        }
        let policy = state.policy
        let bounded = CompletionText.stableContext(prefix, location: selection.location,
                                                   minimum: policy.contextCharacters, chunk: policy.contextCharacters / 3)
        state.fieldStatus = "Проверка контекста и координат"
        guard bounded.count >= 3, PrivacyGate.allowsContext(bounded) else { return nil }
        let fieldFrame = frame(field)
        // Many hosts (web views above all) return nothing for an empty range; the glyph
        // before the caret gives the same position.
        var caretRect = rect(field, range: CFRange(location: selection.location, length: 0))
        if caretRect == nil, selection.location > 0, bounded.last?.isNewline == false,
           let previous = rect(field, range: CFRange(location: selection.location - 1, length: 1)) {
            caretRect = CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        // Chromium and WebKit editors answer only through text markers: the bounds of the
        // collapsed selection are the caret itself.
        if caretRect == nil, let markers = attribute(field, "AXSelectedTextMarkerRange") {
            var bounds: CFTypeRef?
            var marked = CGRect.zero
            if AXUIElementCopyParameterizedAttributeValue(field, "AXBoundsForTextMarkerRange" as CFString, markers, &bounds) == .success,
               let bounds, CFGetTypeID(bounds) == AXValueGetTypeID(),
               AXValueGetValue(unsafeDowncast(bounds, to: AXValue.self), .cgRect, &marked),
               marked.height > 0, marked.height < 400, marked.width < 4 {
                caretRect = marked
            }
        }
        guard var caret = caretRect else {
            guard let fieldFrame else { return nil }
            state.fieldStatus = "Поле без координат курсора: подсказка рядом с полем"
            return Field(element: field, pid: target.pid, location: selection.location, prefix: bounded,
                         caret: nil, container: fieldFrame, font: .systemFont(ofSize: 13), color: .labelColor)
        }
        caret.origin.y = (NSScreen.screens.first?.frame.maxY ?? 0) - caret.maxY
        // Telegram reports text rectangles exactly one line above the glyphs.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "ru.keepcoder.Telegram" {
            caret.origin.y -= caret.height
        }
        var container = fieldFrame ?? caret.insetBy(dx: -220, dy: -80)
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
            // Some hosts report caret rectangles in a wrong coordinate space. Their text is
            // still good, so show the suggestion next to the field instead of dropping it.
            state.log("caret \(caret.integral) outside field \((fieldFrame ?? container).integral)")
            guard let fieldFrame else { return nil }
            state.fieldStatus = "Координаты курсора вне поля: подсказка рядом с полем"
            return Field(element: field, pid: target.pid, location: selection.location, prefix: bounded,
                         caret: nil, container: fieldFrame, font: .systemFont(ofSize: 13), color: .labelColor)
        }
        state.fieldStatus = "Поле готово · \(Int(style.font.pointSize)) pt · \(bounded.count) символов контекста"
        return Field(element: field, pid: target.pid, location: selection.location, prefix: bounded,
                     caret: caret, container: container, font: style.font, color: style.color)
    }

    /// The remainder to show when `field` is exactly the old field plus the accepted text.
    private func continuation(for field: Field) -> String? {
        guard let pending = acceptedContinuation, field.pid == pending.field.pid,
              field.location == pending.field.location + pending.inserted.utf16.count,
              field.prefix.hasSuffix(String((pending.field.prefix + pending.inserted).suffix(48))) else { return nil }
        switch (field.element, pending.field.element) {
        case (nil, nil): return pending.remainder
        case let (now?, before?): return CFEqual(now, before) ? pending.remainder : nil
        default: return nil
        }
    }

    private func schedule(manual: Bool) {
        // Hosts report one edit several times; a suggestion that still fits stays put.
        if !manual, !suggestion.isEmpty, let shown = current, let field = readField(),
           field.location == shown.location, field.prefix == shown.prefix { return }
        dismiss()
        guard state.enabled, state.modelReady, state.policy.allowsAutomatic else { return }
        let id = requestID
        if acceptedContinuation != nil, let field = readField(), let rest = continuation(for: field) {
            acceptedContinuation = nil
            cache.insert(rest, for: field.prefix)
            publish(rest, field: field, id: id)
            return
        }
        guard !state.manualOnly || manual else { return }
        let policy = state.policy
        pending = Task { [weak self] in
            guard let self else { return }
            do {
                if !manual { try await Task.sleep(for: .milliseconds(policy.debounceMilliseconds)) }
                try Task.checkCancellation()
                // One field read per request; any later key, click or AX change replaces
                // `requestID`, which is what keeps a published suggestion from going stale.
                guard requestID == id else { return }
                guard let field = readField() else { state.log("no field: \(state.fieldStatus)"); return }
                if let rest = continuation(for: field) {
                    acceptedContinuation = nil
                    publish(rest, field: field, id: id)
                    return
                }
                if let cached = cache.value(for: field.prefix) {
                    publish(cached, field: field, id: id)
                    return
                }
                // The user's own habit comes first, and the model carries on from it.
                var own = ""
                if state.memoryEnabled, let habit = state.memory.continuation(of: field.prefix, maxWords: min(3, policy.maxWords)) {
                    state.log("memory: \(habit.count) chars")
                    own = habit
                    publish(own, field: field, id: id)
                }
                current = field
                let habit = own
                let lead = CompletionPrompt.lead(style: state.memoryEnabled ? styleCard : "", screen: state.screenEnabled ? screenContext : "")
                var result = try await state.engine.complete(prefix: field.prefix + own, lead: lead, maxTokens: policy.maxTokens,
                                                             maxWords: policy.maxWords) { [weak self] partial in
                    Task { @MainActor in self?.publishPartial(habit + partial, id: id) }
                }
                if !own.isEmpty {
                    result = InferenceResult(text: own + result.text, tokenCount: result.tokenCount,
                                             milliseconds: result.milliseconds, reusedTokens: result.reusedTokens)
                }
                try Task.checkCancellation()
                guard requestID == id else { return }
                cache.insert(result.text, for: field.prefix)
                state.record(result)
                state.log("model: \(result.text.count) chars in \(Int(result.milliseconds)) ms, context \(field.prefix.count)")
                if result.text.isEmpty { suggestion = ""; panel.hide() }
                else { publish(result.text, field: field, id: id) }
            } catch is CancellationError {} catch {
                state.log("completion failed: \(error)")
                if requestID == id { state.error = error.localizedDescription; dismiss() }
            }
        }
    }

    private func publishPartial(_ text: String, id: UUID) {
        guard requestID == id, let current else { return }
        publish(text, field: current, id: id)
    }

    private func publish(_ text: String, field: Field, id: UUID) {
        guard requestID == id, state.enabled, !text.isEmpty else { return }
        current = field
        suggestion = text
        state.log("show \(field.caret == nil ? "pill" : "inline") \(text.count) chars, source \(field.element == nil ? "keys" : "ax")")
        if let caret = field.caret {
            panel.show(text, caret: caret, container: field.container, font: field.font, color: field.color)
        } else {
            panel.showPill(text, anchor: field.container, insideWindow: field.element == nil)
        }
    }

    private func accept(all: Bool, field: Field) {
        state.log("tab accept, typing=\(insertsByTyping || field.element == nil)")
        let text = all ? suggestion : CompletionText.nextWord(suggestion)
        guard !text.isEmpty else { return }
        let remainder = String(suggestion.dropFirst(text.count))
        dismiss()
        acceptedContinuation = remainder.isEmpty ? nil : (field, text, remainder)
        state.acceptedCharacters += text.count
        // Insert after the tap callback has returned: Tab is already consumed.
        Task { [weak self] in
            guard let self else { return }
            await insert(text, into: field)
            if field.element == nil { typed.apply(.text(text)) }
            if state.memoryEnabled, observedField != nil { written.apply(.text(text)) }
            // A change notification may already have brought the remainder back.
            if suggestion.isEmpty { schedule(manual: true) }
        }
    }

    private func caretLocation(of element: AXUIElement) -> Int? {
        var selection = CFRange()
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cfRange, &selection) else { return nil }
        return selection.location
    }

    /// Inserts through Accessibility when the host supports it, otherwise by typing.
    private func insert(_ text: String, into field: Field) async {
        if let element = field.element, !insertsByTyping {
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
            if settable.boolValue,
               AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
                // Some hosts (Telegram) apply the write a moment later. Typing as well
                // would insert the word twice, so wait before concluding it was ignored.
                var moved = caretLocation(of: element).map { $0 != field.location } ?? true
                if !moved {
                    try? await Task.sleep(for: .milliseconds(120))
                    moved = caretLocation(of: element).map { $0 != field.location } ?? true
                }
                if moved {
                    var range = CFRange(location: field.location + text.utf16.count, length: 0)
                    if let value = AXValueCreate(.cfRange, &range) {
                        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
                    }
                    return
                }
                state.log("AX insert ignored, typing instead")
            }
        }
        type(text, pid: field.pid)
        // Typed events reach the host asynchronously; let it apply them first.
        if field.element != nil { try? await Task.sleep(for: .milliseconds(60)) }
    }

    /// Unicode key events preserve the clipboard and work in web and custom fields.
    /// Hosts read only a short string per event, so send small whole-character chunks.
    private func type(_ text: String, pid: pid_t) {
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty, let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
            for event in [down, up] {
                event.flags = [] // Option may still be held from Option-Tab.
                event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.postToPid(pid)
            }
            chunk.removeAll(keepingCapacity: true)
        }
        for character in text {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > 16 { flush() }
            chunk.append(contentsOf: units)
        }
        flush()
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
        typed.apply(.reset)
        commitWritten()
        cache.clear()
        Task { await state.engine.resetContext() }
    }
}
