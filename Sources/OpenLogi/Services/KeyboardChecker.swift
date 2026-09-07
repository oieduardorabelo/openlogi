import Combine
import Foundation
import IOKit.hid

struct KeyboardCheckEvent: Identifiable, Sendable {
    enum Phase: String, Sendable {
        case pressed = "Down"
        case released = "Up"
        case repeated = "Repeat"
        case modifiersChanged = "Modifiers"
    }

    let id = UUID()
    let timestamp = Date()
    let stroke: KeyStroke
    let phase: Phase
    var capsLock: Bool? = nil

    var keyName: String {
        if phase == .modifiersChanged {
            return Self.modifierNames[stroke.keyCode] ?? "Modifier \(stroke.keyCode)"
        }
        return stroke.displayName
    }

    var source: String {
        switch stroke.kind {
        case .keyboard: "Keyboard"
        case .media: "Media"
        case .logitechFunction: "Logitech"
        }
    }

    private static let modifierNames = [
        54: "Right Command", 55: "Left Command", 56: "Left Shift", 57: "Caps Lock",
        58: "Left Option", 59: "Left Control", 60: "Right Shift", 61: "Right Option",
        62: "Right Control", 63: "Fn"
    ]
}

struct DetectedKeyboard: Identifiable, Sendable {
    let id: UInt64
    let name: String
    let transport: String
    let vendorID: Int
    let productID: Int

    var details: String {
        String(format: "%@ · vendor %04X · product %04X", transport, vendorID, productID)
    }

    static func discover() -> [Self] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad]
        ] as CFArray)
        // Enumeration does not seize the devices or register input callbacks.
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        return devices.map { device in
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
            return Self(
                id: id,
                name: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Keyboard",
                transport: IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "Unknown connection",
                vendorID: IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0,
                productID: IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
            )
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

@MainActor
final class KeyboardChecker: ObservableObject {
    @Published var devices: [DetectedKeyboard] = []
    @Published private(set) var events: [KeyboardCheckEvent] = []
    @Published private(set) var heldKeys: [KeyStroke] = []
    @Published private(set) var modifiers: ShortcutModifiers = []
    @Published private(set) var capsLock = false

    func record(_ event: KeyboardCheckEvent) {
        events.insert(event, at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
        if event.stroke.kind != .media { modifiers = event.stroke.modifiers }
        if let capsLock = event.capsLock { self.capsLock = capsLock }
        switch event.phase {
        case .pressed, .repeated:
            if !heldKeys.contains(where: { sameKey($0, event.stroke) }) {
                var key = event.stroke
                key.modifiers = []
                heldKeys.append(key)
            }
        case .released:
            heldKeys.removeAll { sameKey($0, event.stroke) }
        case .modifiersChanged:
            break
        }
    }

    func clearHistory() {
        events.removeAll()
    }

    func resetHeldKeys() {
        heldKeys.removeAll()
        modifiers = []
        capsLock = false
    }

    private func sameKey(_ lhs: KeyStroke, _ rhs: KeyStroke) -> Bool {
        lhs.kind == rhs.kind && lhs.keyCode == rhs.keyCode
    }
}
