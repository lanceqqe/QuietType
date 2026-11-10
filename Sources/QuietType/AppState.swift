import AppKit
import Observation
import QuietTypeCore

@MainActor @Observable
final class AppState {
    let engine = LocalModel()
    let store = ModelStore()
    var enabled = true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "enabled")
            if !enabled { onPause?(); cancelPlayground() }
        }
    }
    var modelReady = false
    var loading = false
    var installing = false
    var installationProgress = 0.0
    var installationFile = ""
    var error: String?
    var accessibilityGranted = AXIsProcessTrusted()
    var keyboardGranted = false
    var activeApplication = "Нет текстового поля"
    var fieldStatus = "Ожидание текстового поля"
    var latency: Double?
    var generatedCount = 0
    var acceptedCharacters = 0
    var reusedTokens = 0
    var playground = "Привет! Хотел бы обсудить с тобой"
    var playgroundSuggestion = ""
    var playgroundBusy = false
    var modelTask: Task<Void, Never>?
    var playgroundTask: Task<Void, Never>?
    private var playgroundRequestID = UUID()
    var onPause: (() -> Void)?
    var onPermissionsChanged: (() -> Void)?

    var energyMode: EnergyMode {
        didSet { UserDefaults.standard.set(energyMode.rawValue, forKey: "energyMode"); onPause?() }
    }
    var manualOnly: Bool {
        didSet { UserDefaults.standard.set(manualOnly, forKey: "manualOnly"); onPause?() }
    }
    var excludedApps: String {
        didSet { UserDefaults.standard.set(excludedApps, forKey: "excludedApps"); onPause?() }
    }

    init() {
        energyMode = EnergyMode(rawValue: UserDefaults.standard.string(forKey: "energyMode") ?? "") ?? .automatic
        manualOnly = UserDefaults.standard.bool(forKey: "manualOnly")
        excludedApps = UserDefaults.standard.string(forKey: "excludedApps") ?? ""
        enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    }

    var exclusions: [String] {
        excludedApps.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var policy: EnergyPolicy {
        let thermal: ThermalLevel = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
        return EnergyPolicy(mode: energyMode, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: thermal)
    }

    var status: String {
        if installing { return "Установка модели" }
        if loading { return "Загрузка модели" }
        if !modelReady { return "Нужна модель" }
        if !enabled { return "На паузе" }
        if !accessibilityGranted || !keyboardGranted { return "Нужен доступ к вводу" }
        if !policy.allowsAutomatic { return "Пауза: Mac перегрет" }
        return manualOnly ? "По запросу" : "Готов к работе"
    }

    func loadModel() {
        guard !loading, !installing, !modelReady else { return }
        guard ModelAssets.isInstalled else { return }
        loading = true
        error = nil
        modelTask = Task {
            defer { loading = false; modelTask = nil }
            do {
                try await engine.load(from: ModelAssets.directory)
                try Task.checkCancellation()
                modelReady = true
            } catch is CancellationError {} catch {
                self.error = "Не удалось загрузить модель: \(error.localizedDescription)"
            }
        }
    }

    func installModel() {
        guard !installing, !loading else { return }
        installing = true
        error = nil
        modelTask = Task {
            do {
                try await store.install { [weak self] file, fraction in
                    Task { @MainActor in self?.installationFile = file; self?.installationProgress = fraction }
                }
                installing = false
                modelTask = nil
                loadModel()
            } catch is CancellationError {
                installing = false; modelTask = nil
            } catch {
                self.error = error.localizedDescription
                installing = false; modelTask = nil
            }
        }
    }

    func unloadModel() {
        guard !loading, !installing else { return }
        onPause?()
        cancelPlayground()
        modelReady = false
        loading = true
        modelTask = Task {
            await engine.unload()
            loading = false
            modelTask = nil
        }
    }

    func requestAccessibility() {
        // The public trust request registers this running app with macOS.
        // TCC owns the list entry and the user alone enables its switch.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if accessibilityGranted { refreshPermissions(); return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        onPermissionsChanged?()
    }

    func testCompletion(afterDelay: Bool = false) {
        cancelPlayground()
        guard modelReady, enabled, policy.allowsAutomatic,
              playground.count >= 3, PrivacyGate.allowsContext(playground) else { return }
        playgroundBusy = true
        error = nil
        let prefix = String(playground.suffix(policy.contextCharacters))
        let tokens = policy.maxTokens
        let words = policy.maxWords
        let delay = policy.debounceMilliseconds
        let id = playgroundRequestID
        playgroundTask = Task {
            defer { if playgroundRequestID == id { playgroundBusy = false } }
            do {
                if afterDelay { try await Task.sleep(for: .milliseconds(delay)) }
                let result = try await engine.complete(prefix: prefix, maxTokens: tokens, maxWords: words)
                try Task.checkCancellation()
                guard playgroundRequestID == id else { return }
                playgroundSuggestion = result.text
                record(result)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    func cancelPlayground() {
        playgroundTask?.cancel()
        playgroundTask = nil
        playgroundRequestID = UUID()
        playgroundSuggestion = ""
        playgroundBusy = false
    }

    func editPlayground(_ text: String) {
        playground = text
        testCompletion(afterDelay: true)
    }

    func record(_ result: InferenceResult) {
        latency = result.milliseconds
        reusedTokens = result.reusedTokens
        generatedCount += 1
    }

    func acceptPlayground() {
        guard !playgroundSuggestion.isEmpty else { return }
        let word = CompletionText.nextWord(playgroundSuggestion)
        playground += word
        playgroundSuggestion.removeFirst(word.count)
        acceptedCharacters += word.count
    }
}
