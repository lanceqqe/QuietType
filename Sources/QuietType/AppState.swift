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
    var computeUnits = ""
    var loading = false
    var installing = false
    var installationProgress = 0.0
    var installationFile = ""
    var error: String?
    var accessibilityGranted = AXIsProcessTrusted()
    var keyboardGranted = false
    var activeApplication = "Нет текстового поля"
    var fieldStatus = "Ожидание текстового поля" {
        didSet { if fieldStatus != oldValue { log(fieldStatus) } }
    }
    /// Diagnostic trace of pipeline stages: app name, stage, lengths. Never typed text.
    nonisolated static let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/QuietType.log")
    @ObservationIgnored private let logHandle: FileHandle? = {
        // One file per launch; the previous launch is kept next to it for bug reports.
        let fm = FileManager.default
        let previous = logURL.deletingLastPathComponent().appendingPathComponent("QuietType.previous.log")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: logURL, to: previous)
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chip = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &chip, &size, nil, 0)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        handle?.write(Data("QuietType \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(String(cString: chip)) · \(memory) GB · \(Bundle.main.bundlePath)\n".utf8))
        return handle
    }()
    /// Selects both log files in Finder so they can be sent as they are.
    func revealLogs() {
        let previous = Self.logURL.deletingLastPathComponent().appendingPathComponent("QuietType.previous.log")
        NSWorkspace.shared.activateFileViewerSelecting([Self.logURL, previous].filter { FileManager.default.fileExists(atPath: $0.path) })
    }
    func log(_ message: String) {
        let time = Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
        logHandle?.write(Data("\(time) [\(activeApplication)] \(message)\n".utf8))
    }
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

    /// Personal writing habits; see StyleMemory. Off until the user turns it on.
    var memoryEnabled: Bool {
        didSet { UserDefaults.standard.set(memoryEnabled, forKey: "styleMemory"); onPause?() }
    }
    private(set) var memory = StyleMemory()
    /// Lets the model read what is visible above the field (a chat, a letter). Off by default.
    var screenEnabled: Bool {
        didSet { UserDefaults.standard.set(screenEnabled, forKey: "screenContext"); onPause?() }
    }
    var screenCaptureGranted = CGPreflightScreenCaptureAccess()
    func requestScreenCapture() {
        screenCaptureGranted = CGRequestScreenCaptureAccess()
        if !screenCaptureGranted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
    nonisolated static let memoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuietType/Memory/style.json")

    func learn(_ text: String, app: String) {
        guard memoryEnabled else { return }
        memory.learn(text, app: app)
        let snapshot = memory
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: Self.memoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.memoryURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.memoryURL.path)
        }
    }

    func forgetMemory() {
        memory = StyleMemory()
        try? FileManager.default.removeItem(at: Self.memoryURL)
        onPause?()
    }

    init() {
        memoryEnabled = UserDefaults.standard.bool(forKey: "styleMemory")
        screenEnabled = UserDefaults.standard.bool(forKey: "screenContext")
        if let data = try? Data(contentsOf: Self.memoryURL),
           let saved = try? JSONDecoder().decode(StyleMemory.self, from: data) { memory = saved }
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
            let started = ContinuousClock.now
            do {
                defer { Task { for note in await engine.loadNotes { log("model: \(note)") } } }
                try await engine.load(from: ModelAssets.directory)
                try Task.checkCancellation()
                computeUnits = await engine.computeUnits
                log("model: loaded in \(started.duration(to: .now).components.seconds) s")
                // The first call compiles kernels (tens of seconds on the GPU fallback);
                // pay for it now instead of on the user's first suggestion.
                _ = try? await engine.complete(prefix: "Привет, как", maxTokens: 2)
                await engine.resetContext()
                log("model: ready on \(computeUnits)")
                modelReady = true
            } catch is CancellationError {} catch {
                self.error = "Не удалось загрузить модель: \(error.localizedDescription)"
                log("model: load failed: \(error)")
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
                log("model: install failed: \(error)")
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
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
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
