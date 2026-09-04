import AppKit
@preconcurrency import ApplicationServices
import Combine
import CoreGraphics

@MainActor
final class KeyboardInputActivity: ObservableObject {
    @Published private(set) var lastInput: KeyStroke?

    func record(_ input: KeyStroke) {
        guard lastInput != input else { return }
        lastInput = input
    }
}

@MainActor
final class KeyboardEngine: ObservableObject {
    enum RequiredPermission: String, CaseIterable, Identifiable, Sendable {
        case accessibility
        case inputMonitoring

        var id: Self { self }

        var displayName: String {
            switch self {
            case .accessibility: "Accessibility"
            case .inputMonitoring: "Input Monitoring"
            }
        }
    }

    enum Status: Equatable {
        case stopped
        case permissionRequired(Set<RequiredPermission>)
        case running
        case failed(String)

        var label: String {
            switch self {
            case .stopped: "Stopped"
            case .permissionRequired(let permissions):
                Self.permissionLabel(permissions)
            case .running: "Keyboard remapping active"
            case .failed(let message): message
            }
        }

        private static func permissionLabel(_ permissions: Set<RequiredPermission>) -> String {
            let names = RequiredPermission.allCases
                .filter(permissions.contains)
                .map(\.displayName)
            guard !names.isEmpty else { return "Permissions required" }
            let noun = names.count == 1 ? "permission" : "permissions"
            return "\(names.joined(separator: " and ")) \(noun) required"
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var captureOwner: UUID?
    @Published private(set) var hasRequestedPermission = false
    @Published private(set) var logitechInputStatus: LogitechFunctionKeyMonitor.Status = .inactive

    var isRecording: Bool { captureOwner != nil }

    let activity = KeyboardInputActivity()
    var onFunctionModeChange: (() -> Void)?

    private let store: ShortcutStore
    private let eventWorker = KeyboardEventWorker()
    private var captureHandler: ((KeyStroke) -> Void)?
    private var captureToken: UInt64 = 0
    private var activeCaptureToken: UInt64?
    private var logitechFunctionKeys: LogitechFunctionKeyMonitor?
    private var lastLogitechConfiguration: LogitechConfiguration?
    private var storeObserver: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?

    private struct LogitechConfiguration: Equatable {
        var positions: Set<Int>
        var capturesAll: Bool
    }

    init(store: ShortcutStore) {
        self.store = store
        eventWorker.setHandlers(
            onInput: { [weak self] input in
                Task { @MainActor in self?.recordInput(input) }
            },
            onCapture: { [weak self] token, input in
                Task { @MainActor in self?.completeCapture(token: token, input: input) }
            }
        )
        eventWorker.update(rules: store.rules, isEnabled: store.isEnabled)
        storeObserver = store.$rules
            .removeDuplicates(by: Self.rulesHaveEqualRuntimeBehavior)
            .combineLatest(store.$isEnabled.removeDuplicates())
            .sink { [weak self] rules, isEnabled in
                MainActor.assumeIsolated {
                    self?.refreshRuleConfiguration(rules: rules, isEnabled: isEnabled)
                }
            }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    func start() {
        let missingPermissions = Self.missingPermissions()
        guard missingPermissions.isEmpty else {
            cancelCapture()
            logitechFunctionKeys?.stop()
            logitechFunctionKeys = nil
            lastLogitechConfiguration = nil
            logitechInputStatus = .inactive
            stopEventTap()
            setStatus(.permissionRequired(missingPermissions))
            return
        }
        guard status != .running else {
            refreshLogitechDiversions()
            return
        }
        guard eventWorker.start() else {
            setStatus(.failed("Could not start event monitor"))
            return
        }
        setStatus(.running)
        refreshLogitechDiversions()
    }

    func stop() {
        cancelCapture()
        logitechFunctionKeys?.stop()
        logitechFunctionKeys = nil
        lastLogitechConfiguration = nil
        logitechInputStatus = .inactive
        stopEventTap()
        setStatus(.stopped)
    }

    func refreshLogitechInput() {
        refreshLogitechDiversions()
        logitechFunctionKeys?.refresh()
    }

    private func stopEventTap() {
        eventWorker.stop()
    }

    private func shutdown() {
        store.flush()
        stop()
    }

    func requestRequiredPermissions() {
        let missingPermissions = Self.missingPermissions()
        guard !missingPermissions.isEmpty else {
            start()
            return
        }
        hasRequestedPermission = true
        if missingPermissions.contains(.accessibility) {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
        if missingPermissions.contains(.inputMonitoring) {
            _ = CGRequestListenEventAccess()
        }
        start()
    }

    func openSettings(for permission: RequiredPermission) {
        let pane: String
        switch permission {
        case .accessibility:
            pane = "Privacy_Accessibility"
        case .inputMonitoring:
            pane = "Privacy_ListenEvent"
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func captureNext(owner: UUID, _ handler: @escaping (KeyStroke) -> Void) -> Bool {
        start()
        guard status == .running else {
            return false
        }
        captureHandler = handler
        captureToken &+= 1
        activeCaptureToken = captureToken
        eventWorker.beginCapture(token: captureToken)
        captureOwner = owner
        refreshLogitechDiversions()
        return true
    }

    func cancelCapture(owner: UUID? = nil) {
        guard owner == nil || captureOwner == owner else { return }
        guard captureHandler != nil || activeCaptureToken != nil || captureOwner != nil else { return }
        let token = activeCaptureToken
        activeCaptureToken = nil
        captureHandler = nil
        eventWorker.cancelCapture(token: token)
        captureOwner = nil
        refreshLogitechDiversions()
    }

    private func completeCapture(token: UInt64, input: KeyStroke) {
        guard activeCaptureToken == token, let handler = captureHandler else { return }
        activeCaptureToken = nil
        captureHandler = nil
        captureOwner = nil
        handler(input)
        refreshLogitechDiversions()
    }

    private func recordInput(_ input: KeyStroke) {
        activity.record(input)
        if input.kind == .keyboard,
           input.keyCode == 53,
           input.modifiers.contains(.function) {
            onFunctionModeChange?()
        }
    }

    private func refreshRuleConfiguration(rules: [ShortcutRule], isEnabled: Bool) {
        eventWorker.update(rules: rules, isEnabled: isEnabled)
        refreshLogitechDiversions(rules: rules, isEnabled: isEnabled)
    }

    private func refreshLogitechDiversions() {
        refreshLogitechDiversions(rules: store.rules, isEnabled: store.isEnabled)
    }

    private func refreshLogitechDiversions(rules: [ShortcutRule], isEnabled: Bool) {
        let positions = Set(rules.compactMap { rule -> Int? in
            guard isEnabled, rule.isEnabled else { return nil }
            let input = rule.input.normalizedForInputMatching
            guard input.kind == .logitechFunction else { return nil }
            return LogitechFunctionKeyHID.position(forKeyCode: input.keyCode)
        })

        let configuration = LogitechConfiguration(positions: positions, capturesAll: isRecording)
        guard configuration != lastLogitechConfiguration else { return }
        lastLogitechConfiguration = configuration

        guard !positions.isEmpty || isRecording else {
            logitechFunctionKeys?.update(requiredPositions: [], captureAll: false)
            return
        }

        if logitechFunctionKeys == nil {
            let worker = eventWorker
            let monitor = LogitechFunctionKeyMonitor(
                onKey: { keyCode, isDown in
                    let flags = CGEventSource.flagsState(.combinedSessionState)
                    worker.handleLogitechFunctionKey(
                        keyCode: keyCode,
                        isDown: isDown,
                        modifiers: ShortcutModifiers(eventFlags: flags)
                    )
                },
                onStatus: { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.logitechInputStatus != status else { return }
                        self.logitechInputStatus = status
                    }
                }
            )
            logitechFunctionKeys = monitor
        }
        logitechFunctionKeys?.update(requiredPositions: positions, captureAll: isRecording)
    }

    private static func missingPermissions() -> Set<RequiredPermission> {
        var result = Set<RequiredPermission>()
        if !AXIsProcessTrusted() { result.insert(.accessibility) }
        if !CGPreflightListenEventAccess() { result.insert(.inputMonitoring) }
        return result
    }

    private func setStatus(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
    }

    private nonisolated static func rulesHaveEqualRuntimeBehavior(
        _ lhs: [ShortcutRule],
        _ rhs: [ShortcutRule]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.input == right.input
                && left.output == right.output
                && left.systemAction == right.systemAction
                && left.isEnabled == right.isEnabled
        }
    }

}
