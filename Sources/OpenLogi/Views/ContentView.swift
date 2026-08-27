import AppKit
import SwiftUI

struct ContentView: View {
    let store: ShortcutStore
    let engine: KeyboardEngine
    let fnLock: LogitechFnLockController

    var body: some View {
        ZStack {
            AppBrand.background
                .ignoresSafeArea()
            VStack(spacing: 0) {
                ContentHeader(store: store, engine: engine, fnLock: fnLock)
                Rectangle()
                    .fill(AppBrand.lava)
                    .frame(height: 3)
                RulesContent(store: store, engine: engine)
                InputMonitor(activity: engine.activity)
            }
        }
        .font(AppBrand.font(size: 14))
        .foregroundStyle(AppBrand.primaryText)
        .tint(AppBrand.lava)
        .preferredColorScheme(.light)
        .frame(minWidth: 780, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("+ New shortcut", action: store.addRule)
                    .buttonStyle(BrandButtonStyle(kind: .primary))
                    .help("Create a shortcut")
            }
        }
        .background {
            EngineLifecycleObserver(engine: engine, fnLock: fnLock)
        }
    }
}

private struct InputMonitor: View {
    @ObservedObject var activity: KeyboardInputActivity

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(activity.lastInput == nil ? AppBrand.grayLines : AppBrand.green)
                .frame(width: 6, height: 6)
            Text("Last detected input: \(activity.lastInput?.displayName ?? "None")")
                .font(AppBrand.font(size: 11, weight: .medium))
                .foregroundStyle(AppBrand.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 34)
        .background(AppBrand.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppBrand.line)
                .frame(height: 1)
        }
    }
}

private struct EngineLifecycleObserver: View {
    @ObservedObject var engine: KeyboardEngine
    let fnLock: LogitechFnLockController
    @State private var isApplicationActive = NSApplication.shared.isActive

    private var shouldRetryPermission: Bool {
        isApplicationActive && engine.status == .permissionRequired
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                isApplicationActive = NSApplication.shared.isActive
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )) { _ in
                isApplicationActive = true
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification
            )) { _ in
                isApplicationActive = false
            }
            .task(id: shouldRetryPermission) {
                guard shouldRetryPermission else { return }
                await retryPermissionWithBackoff()
            }
            .onDisappear {
                engine.cancelCapture()
            }
    }

    private func refresh() {
        engine.start()
        fnLock.refresh()
        engine.refreshLogitechInput()
    }

    private func retryPermissionWithBackoff() async {
        var delay: UInt64 = 1_500_000_000
        let maximumDelay: UInt64 = 12_000_000_000

        while shouldRetryPermission, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard shouldRetryPermission, !Task.isCancelled else { return }
            engine.start()
            delay = min(delay * 2, maximumDelay)
        }
    }
}

private struct ContentHeader: View {
    let store: ShortcutStore
    @ObservedObject var engine: KeyboardEngine
    @ObservedObject var fnLock: LogitechFnLockController

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenLogi")
                    .font(AppBrand.font(size: 20, weight: .bold))
                    .tracking(0.8)
                statusBadge
            }

            Spacer()

            permissionActions

            fnLockControl

            RemappingToggle(store: store)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(AppBrand.surface)
    }

    @ViewBuilder
    private var fnLockControl: some View {
        switch fnLock.status {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .help("Detecting Logitech Fn mode")
        case .available(let deviceName, let standardFKeys):
            HStack(spacing: 6) {
                Toggle(
                    "Standard F-keys",
                    isOn: Binding(
                        get: { standardFKeys },
                        set: { fnLock.setStandardFKeys($0) }
                    )
                )
                .toggleStyle(.switch)
                Button(action: fnLock.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh Fn mode")
            }
            .font(AppBrand.font(size: 12, weight: .semibold))
            .fixedSize()
            .disabled(fnLock.isBusy)
            .help("\(deviceName): ON makes bare F1–F12 send standard function keys")
        case .unavailable:
            Button("Detect Fn mode", action: fnLock.refresh)
                .buttonStyle(BrandButtonStyle(kind: .secondary))
                .font(AppBrand.font(size: 12, weight: .medium))
                .disabled(fnLock.isBusy)
        }
    }

    private var statusBadge: some View {
        Label(engine.status.label, systemImage: statusIcon)
            .font(AppBrand.font(size: 12, weight: .medium))
            .foregroundStyle(statusColor)
    }

    @ViewBuilder
    private var permissionActions: some View {
        if engine.status == .permissionRequired {
            if engine.hasRequestedPermission {
                Button("Check Again") { engine.start() }
                    .buttonStyle(BrandButtonStyle(kind: .primary))
            } else {
                Button("Grant Access") { engine.requestAccessibilityPermission() }
                    .buttonStyle(BrandButtonStyle(kind: .primary))
            }
            Button("Open Settings") { engine.openAccessibilitySettings() }
                .buttonStyle(BrandButtonStyle(kind: .secondary))
        } else if case .failed = engine.status {
            Button("Retry") { engine.start() }
                .buttonStyle(BrandButtonStyle(kind: .primary))
            Button("Open Settings") { engine.openAccessibilitySettings() }
                .buttonStyle(BrandButtonStyle(kind: .secondary))
        }
    }

    private var statusIcon: String {
        switch engine.status {
        case .running: "checkmark.circle.fill"
        case .permissionRequired: "lock.trianglebadge.exclamationmark"
        case .stopped: "pause.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch engine.status {
        case .running: AppBrand.green
        case .permissionRequired: AppBrand.lava
        case .stopped: AppBrand.secondaryText
        case .failed: AppBrand.lava
        }
    }
}

private struct RemappingToggle: View {
    @ObservedObject var store: ShortcutStore

    var body: some View {
        Toggle(store.isEnabled ? "Remapping ON" : "Remapping OFF", isOn: $store.isEnabled)
            .font(AppBrand.font(size: 13, weight: .semibold))
            .toggleStyle(.switch)
            .fixedSize()
    }
}

private struct RulesContent: View {
    @ObservedObject var store: ShortcutStore
    let engine: KeyboardEngine

    var body: some View {
        Group {
            if store.rules.isEmpty {
                emptyState
            } else {
                rulesList
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppBrand.lava.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(AppBrand.lava)
            }
            VStack(spacing: 6) {
                Text("Map your first key")
                    .font(AppBrand.font(size: 24, weight: .bold))
                Text("Connect a keyboard input to a shortcut or macOS action.")
                    .font(AppBrand.font(size: 14))
                    .foregroundStyle(AppBrand.secondaryText)
            }
            Button("+ New shortcut", action: store.addRule)
                .buttonStyle(BrandButtonStyle(kind: .primary))
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var rulesList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                HStack {
                    Text("SHORTCUTS")
                        .font(AppBrand.font(size: 12, weight: .bold))
                        .tracking(0.8)
                    Spacer()
                    Text("INPUT → TARGET")
                        .font(AppBrand.font(size: 11, weight: .semibold))
                        .foregroundStyle(AppBrand.secondaryText)
                }
                .padding(.horizontal, 4)

                ForEach($store.rules) { $rule in
                    ShortcutRuleRow(
                        rule: $rule,
                        isDuplicate: store.isDuplicate(rule),
                        engine: engine,
                        onDelete: { store.removeRule(id: rule.id) }
                    )
                }

                Text("Compatible Logitech F-keys are detected directly in either Fn mode.")
                    .font(AppBrand.font(size: 12))
                    .foregroundStyle(AppBrand.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .padding(24)
        }
    }
}

private struct ShortcutRuleRow: View {
    @Binding var rule: ShortcutRule
    let isDuplicate: Bool
    let engine: KeyboardEngine
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $rule.isEnabled) {
                Text(rule.isEnabled ? "ON" : "OFF")
                    .font(AppBrand.font(size: 10, weight: .bold))
                    .foregroundStyle(rule.isEnabled ? AppBrand.green : AppBrand.secondaryText)
            }
                .toggleStyle(.switch)
                .fixedSize()
                .help("Enable this rule")

            VStack(alignment: .leading, spacing: 4) {
                TextField("Shortcut name", text: $rule.name)
                    .font(AppBrand.font(size: 14, weight: .semibold))
                    .textFieldStyle(.plain)
                if isDuplicate {
                    Label("Duplicate input", systemImage: "exclamationmark.triangle.fill")
                        .font(AppBrand.font(size: 11, weight: .medium))
                        .foregroundStyle(AppBrand.lava)
                }
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

            ShortcutRecorder(stroke: $rule.input, engine: engine)

            Image(systemName: "arrow.right")
                .foregroundStyle(AppBrand.secondaryText)

            RemapTargetPicker(rule: $rule, engine: engine)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppBrand.secondaryText)
            .help("Delete shortcut")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(AppBrand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppBrand.line, lineWidth: 1)
        }
    }
}
