import AppKit
import CoreGraphics
import Foundation
import IOKit.hidsystem

private enum SystemDefinedEventField {
    // Quartz exposes these event-record fields but does not publish Swift
    // constants for them. Reading them directly avoids main-thread-only NSEvent.
    static let subtype = CGEventField(rawValue: 0x53)!
    static let data1 = CGEventField(rawValue: 0x95)!
    static let data2 = CGEventField(rawValue: 0x96)!
}

/// Owns the synchronous event-tap path on a dedicated run loop. UI work never
/// executes here; only parsing, indexed lookup, suppression, and event posting.
final class KeyboardEventWorker: @unchecked Sendable {
    private struct PhysicalKey: Hashable {
        let kind: ShortcutKind
        let keyCode: Int

        init(_ stroke: KeyStroke) {
            kind = stroke.kind
            keyCode = stroke.keyCode
        }
    }

    private final class StartLatch: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Bool?

        func resolve(_ result: Bool) {
            condition.lock()
            self.result = result
            condition.broadcast()
            condition.unlock()
        }

        func wait() -> Bool {
            condition.lock()
            while result == nil { condition.wait() }
            let result = result ?? false
            condition.unlock()
            return result
        }
    }

    private static let systemDefinedType = CGEventType(rawValue: 14)!
    private static let mediaKeyDown = 0x0a
    private static let mediaKeyUp = 0x0b

    private let runLoopQueue = DispatchQueue(
        label: "com.openlogi.keyboard-event-tap",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private let lifecycleLock = NSLock()

    private var ruleByInput: [KeyStroke: ShortcutRule] = [:]
    private var suppressedUntilRelease = Set<PhysicalKey>()
    private var lastReportedInput: KeyStroke?
    private var captureToken: UInt64?
    private var onInput: (@Sendable (KeyStroke) -> Void)?
    private var onCapture: (@Sendable (UInt64, KeyStroke) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var isStarting = false

    func setHandlers(
        onInput: @escaping @Sendable (KeyStroke) -> Void,
        onCapture: @escaping @Sendable (UInt64, KeyStroke) -> Void
    ) {
        stateLock.lock()
        self.onInput = onInput
        self.onCapture = onCapture
        stateLock.unlock()
    }

    func update(rules: [ShortcutRule], isEnabled: Bool) {
        var lookup: [KeyStroke: ShortcutRule] = [:]
        if isEnabled {
            for rule in rules where rule.isEnabled {
                let input = rule.input.normalizedForInputMatching
                if lookup[input] == nil { lookup[input] = rule }
            }
        }

        stateLock.lock()
        ruleByInput = lookup
        stateLock.unlock()
    }

    func beginCapture(token: UInt64) {
        stateLock.lock()
        captureToken = token
        stateLock.unlock()
    }

    func cancelCapture(token: UInt64? = nil) {
        stateLock.lock()
        if token == nil || captureToken == token { captureToken = nil }
        stateLock.unlock()
    }

    func handleLogitechFunctionKey(keyCode: Int, isDown: Bool, modifiers: ShortcutModifiers) {
        let stroke = KeyStroke.logitechFunction(keyCode, modifiers: modifiers)
        var capturedToken: UInt64?
        var matchedRule: ShortcutRule?
        var inputHandler: (@Sendable (KeyStroke) -> Void)?
        var captureHandler: (@Sendable (UInt64, KeyStroke) -> Void)?

        stateLock.lock()
        if isDown {
            if lastReportedInput != stroke {
                lastReportedInput = stroke
                inputHandler = onInput
            }
            if let token = captureToken {
                captureToken = nil
                capturedToken = token
                captureHandler = onCapture
            } else {
                matchedRule = ruleByInput[stroke.normalizedForInputMatching]
            }
        } else if lastReportedInput?.kind == stroke.kind,
                  lastReportedInput?.keyCode == stroke.keyCode {
            lastReportedInput = nil
        }
        stateLock.unlock()

        inputHandler?(stroke)
        if let capturedToken {
            captureHandler?(capturedToken, stroke)
        } else if let matchedRule {
            KeyboardOutput.execute(matchedRule)
        }
    }

    func start() -> Bool {
        lifecycleLock.lock()
        if runLoop != nil {
            lifecycleLock.unlock()
            return true
        }
        if isStarting {
            lifecycleLock.unlock()
            return false
        }
        isStarting = true
        lifecycleLock.unlock()

        let latch = StartLatch()
        runLoopQueue.async { [self] in
            runEventTap(latch: latch)
        }
        let result = latch.wait()

        lifecycleLock.lock()
        isStarting = false
        lifecycleLock.unlock()
        return result
    }

    func stop() {
        lifecycleLock.lock()
        let runLoop = self.runLoop
        lifecycleLock.unlock()
        guard let runLoop else { return }

        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
        runLoopQueue.sync {}

        stateLock.lock()
        captureToken = nil
        suppressedUntilRelease.removeAll(keepingCapacity: true)
        lastReportedInput = nil
        stateLock.unlock()
    }

    private func runEventTap(latch: StartLatch) {
        let eventTypes: [CGEventType] = [.keyDown, .keyUp, Self.systemDefinedType]
        let mask = eventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: userInfo
        ) else {
            latch.resolve(false)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lifecycleLock.lock()
        eventTap = tap
        runLoopSource = source
        self.runLoop = runLoop
        lifecycleLock.unlock()
        latch.resolve(true)

        CFRunLoopRun()

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)

        lifecycleLock.lock()
        eventTap = nil
        runLoopSource = nil
        self.runLoop = nil
        lifecycleLock.unlock()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            suppressedUntilRelease.removeAll(keepingCapacity: true)
            lastReportedInput = nil
            stateLock.unlock()
            lifecycleLock.lock()
            let eventTap = self.eventTap
            lifecycleLock.unlock()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == KeyboardOutput.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }
        guard let parsed = parse(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }

        let physicalKey = PhysicalKey(parsed.stroke)
        var capturedToken: UInt64?
        var matchedRule: ShortcutRule?
        var suppress = false
        var inputHandler: (@Sendable (KeyStroke) -> Void)?
        var captureHandler: (@Sendable (UInt64, KeyStroke) -> Void)?

        stateLock.lock()
        if parsed.isDown {
            if lastReportedInput != parsed.stroke {
                lastReportedInput = parsed.stroke
                inputHandler = onInput
            }
            if let token = captureToken {
                captureToken = nil
                suppressedUntilRelease.insert(physicalKey)
                capturedToken = token
                captureHandler = onCapture
                suppress = true
            } else if let rule = ruleByInput[parsed.stroke.normalizedForInputMatching] {
                suppressedUntilRelease.insert(physicalKey)
                if !parsed.isRepeat || rule.systemAction == nil {
                    matchedRule = rule
                }
                suppress = true
            }
        } else {
            if lastReportedInput?.kind == parsed.stroke.kind,
               lastReportedInput?.keyCode == parsed.stroke.keyCode {
                lastReportedInput = nil
            }
            if suppressedUntilRelease.remove(physicalKey) != nil {
                suppress = true
            }
        }
        stateLock.unlock()

        inputHandler?(parsed.stroke)
        if let capturedToken {
            captureHandler?(capturedToken, parsed.stroke)
        } else if let matchedRule {
            KeyboardOutput.execute(matchedRule)
        }

        return suppress ? nil : Unmanaged.passUnretained(event)
    }

    private func parse(
        type: CGEventType,
        event: CGEvent
    ) -> (stroke: KeyStroke, isDown: Bool, isRepeat: Bool)? {
        if type == .keyDown || type == .keyUp {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = ShortcutModifiers(eventFlags: event.flags)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return (.keyboard(keyCode, modifiers: modifiers), type == .keyDown, isRepeat)
        }

        guard type == Self.systemDefinedType else {
            return nil
        }
        return Self.parseMediaKey(
            subtype: event.getIntegerValueField(SystemDefinedEventField.subtype),
            data1: event.getIntegerValueField(SystemDefinedEventField.data1)
        )
    }

    static func parseMediaKey(
        subtype: Int64,
        data1 data: Int64
    ) -> (stroke: KeyStroke, isDown: Bool, isRepeat: Bool)? {
        guard subtype == 8 else { return nil }
        let keyCode = Int((data & 0xffff0000) >> 16)
        let state = (data & 0x0000ff00) >> 8
        guard state == Self.mediaKeyDown || state == Self.mediaKeyUp else {
            return nil
        }
        return (.media(keyCode), state == Self.mediaKeyDown, false)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let worker = Unmanaged<KeyboardEventWorker>.fromOpaque(userInfo).takeUnretainedValue()
        return worker.handle(type: type, event: event)
    }
}

enum KeyboardOutput {
    static let syntheticEventTag: Int64 = 0x4f50454e4c4f4749
    private static let mediaKeyDown = 0x0a
    private static let mediaKeyUp = 0x0b
    private static let systemDefinedType = CGEventType(rawValue: 14)!
    private static let queue = DispatchQueue(
        label: "com.openlogi.keyboard-output",
        qos: .userInteractive
    )

    static func execute(_ rule: ShortcutRule) {
        queue.async {
            executeNow(rule)
        }
    }

    private static func executeNow(_ rule: ShortcutRule) {
        if let action = rule.systemAction {
            perform(action)
        } else {
            post(rule.output)
        }
    }

    private static func post(_ stroke: KeyStroke) {
        switch stroke.kind {
        case .keyboard:
            postKeyboard(stroke)
        case .logitechFunction:
            var standardStroke = stroke
            standardStroke.kind = .keyboard
            postKeyboard(standardStroke)
        case .media:
            postMedia(stroke)
        }
    }

    private static func perform(_ action: SystemAction) {
        if let shortcut = action.shortcut {
            post(shortcut)
            return
        }

        switch action {
        case .missionControl:
            DispatchQueue.main.async {
                let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        case .startScreenSaver:
            DispatchQueue.main.async {
                let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        case .sleepDisplay:
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                process.arguments = ["displaysleepnow"]
                try? process.run()
            }
        default:
            break
        }
    }

    private static func postKeyboard(_ stroke: KeyStroke) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(stroke.keyCode),
                keyDown: isDown
            ) else { continue }
            event.flags = stroke.modifiers.eventFlags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    private static func postMedia(_ stroke: KeyStroke) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let state = isDown ? mediaKeyDown : mediaKeyUp
            let data1 = (stroke.keyCode << 16) | (state << 8)
            guard let event = CGEvent(source: source) else { continue }
            event.type = systemDefinedType
            event.flags = CGEventFlags(rawValue: UInt64(state << 8))
            event.setIntegerValueField(SystemDefinedEventField.subtype, value: 8)
            event.setIntegerValueField(SystemDefinedEventField.data1, value: Int64(data1))
            event.setIntegerValueField(SystemDefinedEventField.data2, value: -1)
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }
}
