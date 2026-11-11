import AppKit
import ApplicationServices
import QuietTypeCore
import ScreenCaptureKit
import Vision

/// Reads what is visible above the focused field: first through Accessibility, and for
/// apps that hide their content from it (Telegram) by recognising text in a picture of
/// the window. Nothing read here is stored or logged; it lives in memory until the next read.
enum ScreenReader {
    struct Reading: Sendable {
        let text: String
        let source: String
    }

    /// `element` is the focused field. Runs off the main thread: a large page takes a while.
    static func read(element: AXUIElement, pid: pid_t, allowCapture: Bool) async -> Reading {
        nonisolated(unsafe) let field = element
        let viaAccessibility = await Task.detached(priority: .utility) { accessibilityText(field: field) }.value
        guard let viaAccessibility else { return Reading(text: "", source: "none") }
        if viaAccessibility.text.count >= 40 || !allowCapture || !CGPreflightScreenCaptureAccess() {
            return Reading(text: viaAccessibility.text, source: "ax")
        }
        let recognised = (try? await recognisedText(pid: pid, field: viaAccessibility.field)) ?? ""
        return recognised.count > viaAccessibility.text.count
            ? Reading(text: recognised, source: "ocr") : Reading(text: viaAccessibility.text, source: "ax")
    }

    // MARK: Accessibility

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Top-left-origin frame, as Accessibility reports it.
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func accessibilityText(field: AXUIElement) -> (text: String, field: CGRect)? {
        guard let fieldFrame = frame(field), let rawWindow = attribute(field, kAXWindowAttribute),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(rawWindow, to: AXUIElement.self)
        let windowFrame = frame(window) ?? .infinite
        let deadline = ContinuousClock.now + .milliseconds(400)
        var fragments: [ScreenText.Fragment] = []
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard visited < 2_500, depth < 48, ContinuousClock.now < deadline, !CFEqual(element, field) else { return }
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == "AXStaticText" || role == "AXHeading" {
                let text = (attribute(element, kAXValueAttribute) as? String) ?? (attribute(element, kAXTitleAttribute) as? String) ?? ""
                if text.count >= 2, let frame = frame(element), frame.height > 0, windowFrame.intersects(frame) {
                    fragments.append(.init(text: String(text.prefix(600)), frame: frame))
                }
                if role == "AXStaticText" { return }
            }
            guard role != "AXMenuBar", role != "AXToolbar",
                  let children = (attribute(element, kAXVisibleChildrenAttribute) ?? attribute(element, kAXChildrenAttribute)) as? [AXUIElement]
            else { return }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return (ScreenText.assemble(fragments, field: fieldFrame), fieldFrame)
    }

    // MARK: Picture of the window

    /// Recognises the text in the window's column above the field. Needs Screen Recording
    /// permission; the picture is dropped as soon as the text is read.
    private static func recognisedText(pid: pid_t, field: CGRect) async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.contains(CGPoint(x: field.midX, y: field.midY))
        }) else { return "" }
        let top = max(window.frame.minY, field.minY - 700)
        let region = CGRect(x: field.minX, y: top, width: field.width, height: field.minY - top)
        guard region.height >= 40, region.width >= 80 else { return "" }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        let scale = CGFloat(SCContentFilter(desktopIndependentWindow: window).pointPixelScale)
        configuration.width = Int(region.width * scale)
        configuration.height = Int(region.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        return try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ru-RU", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let fragments = (request.results ?? []).compactMap { observation -> ScreenText.Fragment? in
                guard let best = observation.topCandidates(1).first, best.confidence > 0.4,
                      // Message timestamps and counters are noise for the model.
                      best.string.range(of: #"^[\d:.,\s✓]+$"#, options: .regularExpression) == nil else { return nil }
                let box = observation.boundingBox   // normalised, origin at the bottom left
                return .init(text: best.string, frame: CGRect(
                    x: region.minX + box.minX * region.width, y: region.minY + (1 - box.maxY) * region.height,
                    width: box.width * region.width, height: box.height * region.height))
            }
            return ScreenText.assemble(fragments, field: field)
        }.value
    }
}
