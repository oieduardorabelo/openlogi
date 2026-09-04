import CoreGraphics
import Foundation
import IOKit.hidsystem

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt64

    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
    static let function = Self(rawValue: 1 << 4)

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(eventFlags: CGEventFlags) {
        var value: ShortcutModifiers = []
        if eventFlags.contains(.maskCommand) { value.insert(.command) }
        if eventFlags.contains(.maskAlternate) { value.insert(.option) }
        if eventFlags.contains(.maskControl) { value.insert(.control) }
        if eventFlags.contains(.maskShift) { value.insert(.shift) }
        if eventFlags.contains(.maskSecondaryFn) { value.insert(.function) }
        self = value
    }

    var eventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    var displayName: String {
        var result = ""
        if contains(.function) { result += "fn " }
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

enum ShortcutKind: String, Codable, Sendable {
    case keyboard
    case logitechFunction
    case media
}

struct KeyStroke: Codable, Hashable, Sendable {
    var kind: ShortcutKind
    var keyCode: Int
    var modifiers: ShortcutModifiers

    static func keyboard(_ keyCode: Int, modifiers: ShortcutModifiers = []) -> Self {
        Self(kind: .keyboard, keyCode: keyCode, modifiers: modifiers)
    }

    static func media(_ keyCode: Int) -> Self {
        Self(kind: .media, keyCode: keyCode, modifiers: [])
    }

    static func logitechFunction(_ keyCode: Int, modifiers: ShortcutModifiers = []) -> Self {
        Self(kind: .logitechFunction, keyCode: keyCode, modifiers: modifiers)
    }

    var displayName: String {
        switch kind {
        case .keyboard:
            var displayModifiers = modifiers
            if Self.functionKeyCodes.contains(keyCode) {
                displayModifiers.remove(.function)
            }
            let name = Self.keyboardNames[keyCode] ?? "Key \(keyCode)"
            let prefix = Self.functionKeyCodes.contains(keyCode) ? "Standard " : ""
            return displayModifiers.displayName + prefix + name
        case .logitechFunction:
            return "Logi " + (Self.keyboardNames[keyCode] ?? "F-key \(keyCode)")
        case .media:
            return Self.mediaNames[keyCode] ?? "Special \(keyCode)"
        }
    }

    var normalizedForInputMatching: Self {
        if kind == .media, keyCode == Int(NX_KEYTYPE_LAUNCH_PANEL) {
            return .logitechFunction(118)
        }

        if kind == .logitechFunction {
            var normalized = self
            normalized.modifiers = []
            return normalized
        }

        guard kind == .keyboard, Self.functionKeyCodes.contains(keyCode) else { return self }
        var normalized = self
        normalized.modifiers.remove(.function)
        return normalized
    }

    /// HID++ function-key reports identify a physical Logitech key, not an
    /// event type that Quartz can synthesize. Emit the corresponding standard
    /// macOS function key when one is selected as an output.
    var normalizedForOutput: Self {
        guard kind == .logitechFunction else { return self }
        var normalized = self
        normalized.kind = .keyboard
        normalized.modifiers.remove(.function)
        return normalized
    }

    private static let functionKeyCodes: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90
    ]

    private static let keyboardNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
        51: "Delete", 53: "Escape", 64: "F17", 65: "Keypad .", 67: "Keypad *",
        69: "Keypad +", 71: "Clear", 75: "Keypad /", 76: "Keypad Enter", 78: "Keypad -",
        79: "F18", 80: "F19", 90: "F20", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1",
        84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
        89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 96: "F5", 97: "F6",
        98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
        106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
        115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End",
        120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    private static let mediaNames: [Int: String] = [
        Int(NX_KEYTYPE_SOUND_UP): "Volume Up",
        Int(NX_KEYTYPE_SOUND_DOWN): "Volume Down",
        Int(NX_KEYTYPE_BRIGHTNESS_UP): "Brightness Up",
        Int(NX_KEYTYPE_BRIGHTNESS_DOWN): "Brightness Down",
        Int(NX_KEYTYPE_MUTE): "Mute",
        Int(NX_KEYTYPE_EJECT): "Eject",
        Int(NX_KEYTYPE_LAUNCH_PANEL): "Launchpad Key (F4)",
        Int(NX_KEYTYPE_PLAY): "Play/Pause",
        Int(NX_KEYTYPE_NEXT): "Next Track",
        Int(NX_KEYTYPE_PREVIOUS): "Previous Track",
        Int(NX_KEYTYPE_FAST): "Fast Forward",
        Int(NX_KEYTYPE_REWIND): "Rewind",
        Int(NX_KEYTYPE_ILLUMINATION_UP): "Keyboard Light Up",
        Int(NX_KEYTYPE_ILLUMINATION_DOWN): "Keyboard Light Down",
        Int(NX_KEYTYPE_ILLUMINATION_TOGGLE): "Keyboard Light Toggle"
    ]
}

enum SystemActionGroup: String, CaseIterable, Identifiable, Sendable {
    case workspace = "Windows & Workspace"
    case systemPanels = "System Panels"
    case securityAndDisplay = "Security & Display"
    case capture = "Screen Capture"

    var id: Self { self }
}

enum SystemAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case missionControl
    case applicationWindows
    case showDesktop
    case showDock
    case launchpad
    case spotlight
    case controlCenter
    case notificationCenter
    case quickNote
    case characterViewer
    case dictation
    case lockScreen
    case startScreenSaver
    case sleepDisplay
    case screenshotFull
    case screenshotSelection
    case screenshotToolbar

    var id: Self { self }

    var group: SystemActionGroup {
        switch self {
        case .missionControl, .applicationWindows, .showDesktop, .showDock, .launchpad:
            .workspace
        case .spotlight, .controlCenter, .notificationCenter, .quickNote, .characterViewer, .dictation:
            .systemPanels
        case .lockScreen, .startScreenSaver, .sleepDisplay:
            .securityAndDisplay
        case .screenshotFull, .screenshotSelection, .screenshotToolbar:
            .capture
        }
    }

    var displayName: String {
        switch self {
        case .missionControl: "Mission Control"
        case .applicationWindows: "Application Windows"
        case .showDesktop: "Show Desktop"
        case .showDock: "Show/Hide Dock"
        case .launchpad: "Launchpad / Apps"
        case .spotlight: "Spotlight"
        case .controlCenter: "Control Center"
        case .notificationCenter: "Notification Center"
        case .quickNote: "Quick Note"
        case .characterViewer: "Emoji & Symbols"
        case .dictation: "Dictation"
        case .lockScreen: "Lock Screen"
        case .startScreenSaver: "Start Screen Saver"
        case .sleepDisplay: "Sleep Display"
        case .screenshotFull: "Capture Full Screen"
        case .screenshotSelection: "Capture Selection"
        case .screenshotToolbar: "Screenshot Toolbar"
        }
    }

    var symbolName: String {
        switch self {
        case .missionControl: "rectangle.3.group"
        case .applicationWindows: "rectangle.stack"
        case .showDesktop: "macwindow"
        case .showDock: "dock.rectangle"
        case .launchpad: "square.grid.3x3"
        case .spotlight: "magnifyingglass"
        case .controlCenter: "switch.2"
        case .notificationCenter: "bell"
        case .quickNote: "note.text.badge.plus"
        case .characterViewer: "face.smiling"
        case .dictation: "mic"
        case .lockScreen: "lock"
        case .startScreenSaver: "sparkles.rectangle.stack"
        case .sleepDisplay: "display"
        case .screenshotFull: "camera.viewfinder"
        case .screenshotSelection: "viewfinder.rectangular"
        case .screenshotToolbar: "rectangle.dashed.badge.record"
        }
    }

    var shortcut: KeyStroke? {
        switch self {
        case .applicationWindows:
            .keyboard(125, modifiers: .control)
        case .showDesktop:
            .keyboard(4, modifiers: .function)
        case .showDock:
            .keyboard(0, modifiers: .function)
        case .launchpad:
            .keyboard(0, modifiers: [.function, .shift])
        case .spotlight:
            .keyboard(49, modifiers: .command)
        case .controlCenter:
            .keyboard(8, modifiers: .function)
        case .notificationCenter:
            .keyboard(45, modifiers: .function)
        case .quickNote:
            .keyboard(12, modifiers: .function)
        case .characterViewer:
            .keyboard(49, modifiers: [.control, .command])
        case .dictation:
            .keyboard(2, modifiers: .function)
        case .lockScreen:
            .keyboard(12, modifiers: [.control, .command])
        case .screenshotFull:
            .keyboard(20, modifiers: [.shift, .command])
        case .screenshotSelection:
            .keyboard(21, modifiers: [.shift, .command])
        case .screenshotToolbar:
            .keyboard(23, modifiers: [.shift, .command])
        case .missionControl, .startScreenSaver, .sleepDisplay:
            nil
        }
    }
}

struct ShortcutRule: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var input: KeyStroke
    var output: KeyStroke
    var systemAction: SystemAction?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String = "New shortcut",
        input: KeyStroke = .keyboard(0),
        output: KeyStroke = .keyboard(11),
        systemAction: SystemAction? = nil,
        isEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.systemAction = systemAction
        self.isEnabled = isEnabled
    }

    var targetDisplayName: String {
        systemAction?.displayName ?? output.normalizedForOutput.displayName
    }
}
