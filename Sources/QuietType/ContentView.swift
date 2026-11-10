import AppKit
import SwiftUI
import QuietTypeCore

private enum Pane: String, CaseIterable, Identifiable {
    case overview = "Обзор", writing = "Проверка текста", model = "Модель", energy = "Энергия", applications = "Приложения"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: "text.cursor"
        case .writing: "square.and.pencil"
        case .model: "cpu"
        case .energy: "leaf"
        case .applications: "app.badge.checkmark"
        }
    }
}

struct ContentView: View {
    @Bindable var state: AppState
    let requestKeyboard: () -> Void
    @State private var selection: Pane? = .overview

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "text.cursor").font(.system(size: 22, weight: .medium)).foregroundStyle(.teal)
                    Text("QuietType").font(.system(size: 20, weight: .semibold))
                }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 25)
                List(Pane.allCases, selection: $selection) { pane in
                    Label(pane.rawValue, systemImage: pane.symbol).tag(pane).padding(.vertical, 4)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Русский + English", systemImage: "character.bubble")
                    Label("Обработка на Mac", systemImage: "lock.shield")
                }.font(.caption).foregroundStyle(.secondary).padding(20)
            }.navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 250)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if let error = state.error { errorBanner(error) }
                    switch selection ?? .overview {
                    case .overview: overview
                    case .writing: writing
                    case .model: model
                    case .energy: energy
                    case .applications: applications
                    }
                }
                .padding(32).frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.teal).frame(minWidth: 780, minHeight: 600)
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $state.enabled) { Label("Подсказки", systemImage: "text.cursor") }
                    .toggleStyle(.switch).help("Приостановить подсказки во всех приложениях")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(selection == .overview ? "Пишите в своём ритме." : (selection ?? .overview).rawValue)
                    .font(.system(size: 28, weight: .bold)).tracking(-0.6)
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 15)
            HStack(spacing: 6) {
                Circle().fill(state.modelReady && state.enabled ? Color.teal : Color.secondary).frame(width: 6, height: 6)
                Text(state.status).font(.caption.weight(.medium))
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .accessibilityElement(children: .combine)
        }
    }

    private var subtitle: String {
        switch selection ?? .overview {
        case .overview: "Короткие продолжения ваших мыслей. На русском и английском, прямо на вашем Mac."
        case .writing: "Попробуйте локальную модель перед работой в других приложениях."
        case .model: "Собственная языковая модель. Apple Intelligence не требуется."
        case .energy: "Меньше вычислений во время набора. Никакой генерации в простое."
        case .applications: "Вы решаете, где появляются подсказки."
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !state.modelReady || !state.accessibilityGranted || !state.keyboardGranted {
                VStack(alignment: .leading, spacing: 0) {
                    setupRow("Локальная модель", detail: state.modelReady ? "Qwen3 · готова к работе" : (state.loading ? "Модель установлена, загружаем в память…" : "Один раз скачайте около 763 МиБ"), done: state.modelReady) {
                        Button(state.loading ? "Загрузка…" : (state.installing ? "Установка…" : "Настроить")) { selection = .model }
                    }
                    Divider()
                    setupRow("Доступ к текстовым полям", detail: "Для подсказок в других приложениях", done: state.accessibilityGranted && state.keyboardGranted) {
                        Button("Настроить") { selection = .applications }
                    }
                }.padding(.horizontal, 16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
            }
            playground
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("В строке меню", systemImage: "menubar.rectangle").font(.subheadline.weight(.medium))
                    Text("Закройте это окно и продолжайте писать. Пауза всегда под рукой.").font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Label("Текст остаётся вашим", systemImage: "lock").font(.subheadline.weight(.medium))
                    Text("Без облачных запросов и сохранения написанного на диск.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func setupRow<Control: View>(_ title: String, detail: String, done: Bool, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? Color.teal : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { control() }
        }.padding(.vertical, 15)
    }

    private var writing: some View {
        VStack(alignment: .leading, spacing: 24) {
            playground
            GroupBox("Управление в других приложениях") {
                VStack(spacing: 14) {
                    shortcut("Принять следующее слово", "Tab")
                    shortcut("Принять всю подсказку", "⌥ Tab")
                    shortcut("Скрыть подсказку", "Esc")
                    shortcut("Запросить продолжение", "⌃ ⌥ Пробел")
                }.padding(12)
            }
        }
    }

    private func shortcut(_ text: String, _ key: String) -> some View {
        HStack { Text(text); Spacer(); Text(key).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
    }

    private var playground: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Попробуйте продолжить").font(.headline)
                Spacer()
                if state.playgroundBusy { ProgressView().controlSize(.small).accessibilityLabel("Генерация продолжения") }
            }
            VStack(alignment: .leading, spacing: 0) {
                PlaygroundEditor(text: Binding(get: { state.playground }, set: { state.editPlayground($0) }), suggestion: state.playgroundSuggestion) {
                    guard !state.playgroundSuggestion.isEmpty else { return false }
                    state.acceptPlayground(); return true
                }.frame(height: 210)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
            HStack {
                if let latency = state.latency {
                    Text("\(Int(latency)) мс · кэш: \(state.reusedTokens) токенов").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Qwen3 0.6B · Core ML · локально").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !state.playgroundSuggestion.isEmpty {
                    Button("Принять слово ⇥") { state.acceptPlayground() }.controlSize(.small)
                }
                Button("Продолжить") { state.testCompletion() }.buttonStyle(.borderedProminent)
                    .disabled(!state.modelReady || !state.enabled || state.playgroundBusy || !state.policy.allowsAutomatic)
            }
            if !state.modelReady {
                Button(state.loading ? "Модель загружается. Открыть состояние →" : "Установить или загрузить модель →") { selection = .model }.buttonStyle(.link).font(.callout)
            }
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 22) {
            GroupBox {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: "cpu").font(.system(size: 30, weight: .light)).foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Qwen3 · 0.6B").font(.title2.weight(.semibold))
                            Text("ANEMLL · 6-битные веса · контекст 512 токенов").foregroundStyle(.secondary).font(.callout)
                        }
                        Spacer()
                    }
                    Divider()
                    LabeledContent("Языки", value: "Русский и английский")
                    LabeledContent("Вычисления", value: "CPU + Neural Engine")
                    LabeledContent("Размер загрузки", value: ByteCountFormatter.string(fromByteCount: ModelAssets.downloadBytes, countStyle: .file))
                    LabeledContent("Apple Intelligence", value: "Не требуется")
                    if state.installing {
                        ProgressView(value: state.installationProgress)
                        Text("Скачивание и проверка файлов: \(Int(state.installationProgress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(state.installationFile).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Отменить загрузку") { state.modelTask?.cancel() }
                    } else if state.loading {
                        HStack { ProgressView().controlSize(.small); Text("Загрузка модели… Первый запуск может занять около минуты.").font(.callout) }
                    } else {
                        HStack {
                            if ModelAssets.isInstalled {
                                Button(state.modelReady ? "Выгрузить из памяти" : "Загрузить модель") {
                                    if state.modelReady { state.unloadModel() } else { state.loadModel() }
                                }.buttonStyle(.borderedProminent)
                            } else {
                                Button("Скачать модель") { state.installModel() }.buttonStyle(.borderedProminent)
                            }
                            Button("Открыть папку") {
                                try? FileManager.default.createDirectory(at: ModelAssets.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                                NSWorkspace.shared.open(ModelAssets.directory.deletingLastPathComponent())
                            }
                        }
                    }
                }.padding(16)
            }
            Text("Модель компактная: короткие подсказки появляются быстро, но иногда бывают неточными. Продолжайте печатать, если вариант не подходит.").foregroundStyle(.secondary)
            Text("Core ML сам распределяет операции между CPU и Neural Engine. GPU исключён конфигурацией; доля работы на ANE и расход энергии требуют отдельного профилирования.").font(.callout).foregroundStyle(.secondary)
            Link("Модель и лицензия Apache 2.0 ↗", destination: URL(string: "https://huggingface.co/" + ModelAssets.repository)!)
        }
    }

    private var energy: some View {
        Form {
            Section {
                Picker("Режим работы", selection: $state.energyMode) {
                    ForEach(EnergyMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Только по запросу", isOn: $state.manualOnly)
                Text("Нажмите ⌃⌥Пробел в текстовом поле, чтобы получить продолжение.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Текущие ограничения") {
                LabeledContent("Пауза после ввода", value: "\(state.policy.debounceMilliseconds) мс")
                LabeledContent("Длина продолжения", value: "До \(state.policy.maxTokens) токенов")
                LabeledContent("Контекст", value: "До \(state.policy.contextCharacters) символов")
                LabeledContent("Энергосбережение macOS", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "Включено" : "Выключено")
            }
            Section {
                Text("В энергосбережении и при нагреве подсказки становятся короче, а пауза — длиннее. При критическом нагреве генерация приостанавливается.")
                Text("В простое нет таймера опроса и фоновой генерации. Чтобы освободить память, выгрузите модель в разделе «Модель».")
            }.foregroundStyle(.secondary)
            Section("За этот запуск") {
                LabeledContent("Сгенерировано подсказок", value: "\(state.generatedCount)")
                LabeledContent("Принято символов", value: "\(state.acceptedCharacters)")
            }
        }.formStyle(.grouped).scrollDisabled(true).frame(minHeight: 480)
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 22) {
            GroupBox("Разрешения macOS") {
                VStack(spacing: 0) {
                    setupRow("Универсальный доступ", detail: "Читать контекст и вставлять принятые слова", done: state.accessibilityGranted) {
                        Button("Запросить доступ…") { state.requestAccessibility() }
                    }
                    Divider()
                    setupRow("Клавиши принятия", detail: "Обрабатывать Tab и Escape при показе подсказки", done: state.keyboardGranted) {
                        Button("Разрешить…") { requestKeyboard() }
                    }
                    Button("Проверить разрешения") { state.refreshPermissions() }.padding(.top, 10)
                }.padding(10)
            }
            Text("«Запросить доступ» вызывает системный запрос: macOS добавит QuietType в список. Включите переключатель рядом с приложением; после возвращения разрешение проверится автоматически.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Активное приложение: \(state.activeApplication)").font(.callout).foregroundStyle(.secondary)
            Text(state.fieldStatus).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("Исключить приложения").font(.headline)
                Text("Идентификатор приложения на каждой строке, например com.apple.mail.").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $state.excludedApps).font(.system(.body, design: .monospaced))
                    .frame(height: 100).padding(6).background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .accessibilityLabel("Идентификаторы исключённых приложений")
            }
            Text("Парольные поля, менеджеры паролей и терминалы исключены автоматически. Некоторые редакторы и браузерные приложения не предоставляют нужные данные через Accessibility.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(error).font(.callout).textSelection(.enabled)
            Spacer()
            Button { state.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Скрыть ошибку")
        }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PlaygroundEditor: NSViewRepresentable {
    @Binding var text: String
    var suggestion: String
    var accept: () -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 210))
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 16)
        editor.textContainerInset = NSSize(width: 14, height: 16)
        editor.drawsBackground = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.setAccessibilityLabel("Текст для проверки продолжения")
        editor.delegate = context.coordinator
        editor.string = text
        editor.ghostSuggestion = suggestion
        scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? PreviewTextView else { return }
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }
        editor.ghostSuggestion = suggestion
        editor.updateGhost()
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlaygroundEditor
        init(parent: PlaygroundEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? PreviewTextView)?.updateGhost()
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertTab(_:)),
                  textView.selectedRange().location == textView.string.utf16.count else { return false }
            return parent.accept()
        }
    }
}

@MainActor
private final class PreviewTextView: NSTextView {
    var ghostSuggestion = ""
    private let ghost = GhostTextView(frame: .zero)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if ghost.superview == nil { addSubview(ghost) }
        updateGhost()
    }

    override func layout() { super.layout(); updateGhost() }

    func updateGhost() {
        guard let window, let textContainer, let layoutManager, !ghostSuggestion.isEmpty,
              selectedRange().length == 0, selectedRange().location == string.utf16.count else {
            ghost.isHidden = true; return
        }
        layoutManager.ensureLayout(for: textContainer)
        let screen = firstRect(forCharacterRange: NSRange(location: string.utf16.count, length: 0), actualRange: nil)
        let caret = convert(window.convertFromScreen(screen), from: nil)
        let font = self.font ?? .systemFont(ofSize: 16)
        let height = layoutManager.defaultLineHeight(for: font)
        let left = textContainerInset.width + textContainer.lineFragmentPadding
        ghost.frame = NSRect(x: left, y: caret.minY, width: max(1, bounds.width - left * 2), height: height * 3)
        ghost.configure(text: ghostSuggestion, font: font, color: textColor?.withAlphaComponent(0.45) ?? .secondaryLabelColor,
                        firstLineOffset: max(0, caret.minX - left), lineHeight: height)
        ghost.isHidden = false
    }
}
