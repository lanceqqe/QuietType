import AppKit
import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    lazy var typing = TypingService(state: state)
    func applicationDidFinishLaunching(_ notification: Notification) {
        typing.start()
        state.loadModel()
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
            MenuContent(state: delegate.state)
        } label: {
            Image(systemName: delegate.state.enabled && delegate.state.modelReady ? "text.cursor" : "pause.circle")
                .accessibilityLabel("QuietType: \(delegate.state.status)")
        }
    }
}

private struct MenuContent: View {
    @Bindable var state: AppState
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
        Button("Завершить QuietType") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
