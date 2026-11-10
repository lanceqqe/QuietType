import AppKit
import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    lazy var typing = TypingService(state: state)
    let updater = Updater()
    func applicationDidFinishLaunching(_ notification: Notification) {
        typing.start()
        state.loadModel()
        updater.log = { [state] in state.log($0) }
        updater.start()
    }
    func applicationDidBecomeActive(_ notification: Notification) { state.refreshPermissions() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct QuietTypeApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    var body: some Scene {
        Window("QuietType", id: "main") {
            ContentView(state: delegate.state, requestKeyboard: delegate.typing.requestKeyboardAccess)
        }
        .defaultSize(width: 920, height: 710)
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            MenuContent(state: delegate.state, updater: delegate.updater)
        } label: {
            Image(systemName: delegate.state.enabled && delegate.state.modelReady ? "text.cursor" : "pause.circle")
                .accessibilityLabel("QuietType: \(delegate.state.status)")
        }
    }
}

private struct MenuContent: View {
    @Bindable var state: AppState
    @Bindable var updater: Updater
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("QuietType · \(state.status)")
        Divider()
        Toggle("Подсказывать при вводе", isOn: $state.enabled)
        Toggle("Только по ⌃⌥Пробел", isOn: $state.manualOnly)
        Divider()
        Button("Открыть QuietType…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut(",")
        if state.modelReady { Button("Выгрузить модель из памяти") { state.unloadModel() } }
        else if !state.loading && !state.installing { Button("Загрузить установленную модель") { state.loadModel() } }
        Divider()
        Text(updater.status.isEmpty ? "Версия \(Updater.currentVersion)" : updater.status)
        Button("Проверить обновления") { Task { await updater.check(install: true) } }.disabled(updater.busy)
        Toggle("Обновляться автоматически", isOn: $updater.automatic)
        Divider()
        Button("Завершить QuietType") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
