import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let store: ShortcutStore
    let engine: KeyboardEngine
    let fnLock: LogitechFnLockController

    init() {
        let store = ShortcutStore()
        let fnLock = LogitechFnLockController()
        let engine = KeyboardEngine(store: store)
        self.store = store
        self.engine = engine
        self.fnLock = fnLock
        engine.onFunctionModeChange = { [weak fnLock] in
            fnLock?.refresh()
        }
    }
}

@main
struct OpenLogiApp: App {
    @StateObject private var model = AppModel()

    init() {
        AppBrand.registerFonts()
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Window("OpenLogi", id: "shortcuts") {
            ContentView(store: model.store, engine: model.engine, fnLock: model.fnLock)
        }
        .defaultSize(width: 780, height: 500)

        MenuBarExtra {
            MenuBarContent(store: model.store, engine: model.engine)
        } label: {
            Image(nsImage: Self.menuBarIcon)
                .accessibilityLabel("OpenLogi")
        }
        .menuBarExtraStyle(.menu)
    }

    private static let menuBarIcon: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let icon = NSImage(size: size, flipped: false) { rect in
            NSApplication.shared.applicationIconImage.draw(
                in: rect.insetBy(dx: 1, dy: 1),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        icon.isTemplate = false
        return icon
    }()
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let store: ShortcutStore
    let engine: KeyboardEngine

    var body: some View {
        MenuBarRemappingToggle(store: store)
        EngineStatusText(engine: engine)
        Divider()
        Button("Open Shortcuts…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "shortcuts")
        }
        Button("Quit OpenLogi") {
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct MenuBarRemappingToggle: View {
    @ObservedObject var store: ShortcutStore

    var body: some View {
        Toggle("Remapping Enabled", isOn: $store.isEnabled)
    }
}

private struct EngineStatusText: View {
    @ObservedObject var engine: KeyboardEngine

    var body: some View {
        Text(engine.status.label)
    }
}
