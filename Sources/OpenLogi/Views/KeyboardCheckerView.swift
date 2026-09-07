import AppKit
import SwiftUI

struct KeyboardCheckerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var engine: KeyboardEngine
    @StateObject private var checker = KeyboardChecker()
    @State private var isActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Keyboard Checker", systemImage: "keyboard")
                    .font(AppBrand.font(size: 20, weight: .bold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Connected keyboards")
                    .font(AppBrand.font(size: 13, weight: .semibold))
                if checker.devices.isEmpty {
                    Text("No keyboard detected yet. Connect a keyboard or check Input Monitoring access.")
                        .foregroundStyle(AppBrand.secondaryText)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(checker.devices) { device in
                                HStack {
                                    Text(device.name)
                                    Spacer()
                                    Text(device.details)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(AppBrand.secondaryText)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 76)
                }
            }

            status

            VStack(alignment: .leading, spacing: 8) {
                Text(checker.events.first?.keyName ?? "Press any key…")
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppBrand.lava)
                    .lineLimit(1)
                Text("Held: \(checker.heldKeys.map(\.displayName).joined(separator: " + ").nonempty ?? "None")")
                Text("Modifiers: \(modifierLabel)")
                    .foregroundStyle(AppBrand.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(AppBrand.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Text("Recent events")
                    .font(AppBrand.font(size: 13, weight: .semibold))
                Spacer()
                Button("Clear", action: checker.clearHistory)
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(checker.events) { event in
                        HStack(spacing: 12) {
                            Text(event.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                                .foregroundStyle(AppBrand.secondaryText)
                                .frame(width: 105, alignment: .leading)
                            Text(event.phase.rawValue)
                                .frame(width: 72, alignment: .leading)
                            Text(event.keyName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(event.source) · code \(event.stroke.keyCode)")
                                .foregroundStyle(AppBrand.secondaryText)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Events from all keyboards · Last 100 events, kept only while this checker is open.")
                .font(AppBrand.font(size: 11))
                .foregroundStyle(AppBrand.secondaryText)
        }
        .padding(24)
        .frame(width: 720, height: 580)
        .background(AppBrand.background)
        .foregroundStyle(AppBrand.primaryText)
        .font(AppBrand.font(size: 13))
        .preferredColorScheme(.light)
        .onAppear { setActive(NSApplication.shared.isActive) }
        .onDisappear { setActive(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            setActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            setActive(false)
        }
        .task {
            while !Task.isCancelled {
                let devices = await Task.detached { DetectedKeyboard.discover() }.value
                guard !Task.isCancelled else { return }
                checker.devices = devices
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if !isActive {
            Text("Paused — return to this window to check keys.")
        } else if engine.status == .running {
            Text("Listening — test keys are captured here without running shortcuts. Click Close to finish.")
                .foregroundStyle(AppBrand.green)
        } else {
            HStack {
                Text(engine.status.label)
                Spacer()
                Button("Check access") {
                    engine.requestRequiredPermissions()
                }
                .buttonStyle(BrandButtonStyle(kind: .secondary))
            }
        }
    }

    private var modifierLabel: String {
        var label = checker.modifiers.displayName
        if checker.capsLock { label += " Caps Lock" }
        return label.nonempty ?? "None"
    }

    private func setActive(_ active: Bool) {
        isActive = active
        checker.resetHeldKeys()
        if active {
            engine.beginKeyboardCheck { [weak checker] event in checker?.record(event) }
        } else {
            engine.endKeyboardCheck()
        }
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
