import Foundation
import IOKit.hid

@MainActor
final class LogitechFnLockController: ObservableObject {
    enum Status: Equatable {
        case checking
        case available(deviceName: String, standardFKeys: Bool)
        case unavailable(String)

        var standardFKeys: Bool? {
            if case .available(_, let standardFKeys) = self { return standardFKeys }
            return nil
        }
    }

    @Published private(set) var status: Status = .checking
    @Published private(set) var isBusy = false
    private var watcher: LogitechKeyboardWatcher?
    private var refreshRequestedWhileBusy = false

    init() {
        watcher = LogitechKeyboardWatcher { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard !isBusy else {
            refreshRequestedWhileBusy = true
            return
        }
        run { LogitechFnHID.read() }
    }

    func setStandardFKeys(_ enabled: Bool) {
        guard !isBusy else { return }
        if case .available(let deviceName, _) = status {
            status = .available(deviceName: deviceName, standardFKeys: enabled)
        }
        run { LogitechFnHID.write(standardFKeys: enabled) }
    }

    private func run(_ operation: @escaping @Sendable () -> LogitechFnHID.Result) {
        isBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated, operation: operation).value
            finish(result)
        }
    }

    private func finish(_ result: LogitechFnHID.Result) {
        isBusy = false
        let newStatus = status(for: result)
        if status != newStatus { status = newStatus }
        guard refreshRequestedWhileBusy else { return }
        refreshRequestedWhileBusy = false
        refresh()
    }

    private func status(for result: LogitechFnHID.Result) -> Status {
        switch result {
        case .success(let deviceName, let standardFKeys):
            .available(deviceName: deviceName, standardFKeys: standardFKeys)
        case .failure(let message):
            .unavailable(message)
        }
    }
}

enum LogitechFnHID {
    enum Result: Sendable {
        case success(deviceName: String, standardFKeys: Bool)
        case failure(String)
    }

    private struct Feature {
        let index: UInt8
        let host: UInt8?
    }

    static func read() -> Result {
        withSession { session, feature, deviceName in
            guard let standardFKeys = readStandardFKeys(feature, from: session) else {
                return .failure("Fn Lock unavailable")
            }
            return .success(deviceName: deviceName, standardFKeys: standardFKeys)
        }
    }

    static func write(standardFKeys: Bool) -> Result {
        withSession { session, feature, deviceName in
            let swapValue: UInt8 = standardFKeys ? 0 : 1
            var parameters: [UInt8] = []
            if let host = feature.host { parameters.append(host) }
            parameters.append(swapValue)

            guard session.request(featureIndex: feature.index, function: 1, parameters: parameters) != nil,
                  let confirmed = readStandardFKeys(feature, from: session) else {
                return .failure("Could not update Fn Lock")
            }
            return .success(deviceName: deviceName, standardFKeys: confirmed)
        }
    }

    static func parseStandardFKeys(response: [UInt8], hostPrefixed: Bool) -> Bool? {
        let valueIndex = hostPrefixed ? 5 : 4
        guard response.count > valueIndex else { return nil }
        return response[valueIndex] == 0
    }

    private static func readStandardFKeys(_ feature: Feature, from session: Session) -> Bool? {
        let parameters = feature.host.map { [$0] } ?? []
        guard let response = session.request(
            featureIndex: feature.index,
            function: 0,
            parameters: parameters
        ) else { return nil }
        return parseStandardFKeys(response: response, hostPrefixed: feature.host != nil)
    }

    private static func locateFnFeature(in session: Session) -> Feature? {
        if let index = session.featureIndex(0x40a3), index != 0 {
            guard let hostsIndex = session.featureIndex(0x1815), hostsIndex != 0,
                  let hostsResponse = session.request(featureIndex: hostsIndex, function: 0),
                  hostsResponse.count > 7 else { return nil }
            return Feature(index: index, host: hostsResponse[7])
        }
        for featureID: UInt16 in [0x40a2, 0x40a0] {
            if let index = session.featureIndex(featureID), index != 0 {
                return Feature(index: index, host: nil)
            }
        }
        return nil
    }

    private static func withSession(
        _ operation: (Session, Feature, String) -> Result
    ) -> Result {
        let devices = Session.matchingDevices()
        guard !devices.isEmpty else {
            return .failure("Logitech keyboard not connected")
        }

        var openedDevice = false
        var lastFailure: Result?
        for device in devices {
            guard let session = Session(device: device) else { continue }
            openedDevice = true
            guard let feature = locateFnFeature(in: session) else {
                session.close()
                continue
            }

            let result = operation(session, feature, session.deviceName)
            session.close()
            switch result {
            case .success:
                return result
            case .failure:
                lastFailure = result
            }
        }

        if let lastFailure { return lastFailure }
        return .failure(
            openedDevice
                ? "Fn Lock unavailable on connected Logitech keyboards"
                : "Could not access Logitech keyboards; check Input Monitoring permission"
        )
    }

    private final class Receiver {
        var response: [UInt8]?
        var expectedFeature: UInt8?
        var expectedFunction: UInt8?
    }

    private final class Session {
        private static let softwareID: UInt8 = 0x0a
        private let device: IOHIDDevice
        private let receiver = Receiver()
        private let reportBuffer: UnsafeMutablePointer<UInt8>
        let deviceName: String

        static func matchingDevices() -> [IOHIDDevice] {
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(manager, [
                kIOHIDVendorIDKey: 0x046d,
                kIOHIDPrimaryUsagePageKey: 1,
                kIOHIDPrimaryUsageKey: 6
            ] as CFDictionary)
            guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                return []
            }
            let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>).map(Array.init) ?? []
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return devices
        }

        init?(device: IOHIDDevice) {
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                return nil
            }
            self.device = device
            deviceName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
                ?? "Logitech keyboard"
            reportBuffer = .allocate(capacity: 64)
            reportBuffer.initialize(repeating: 0, count: 64)

            let context = Unmanaged.passUnretained(receiver).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(
                device,
                reportBuffer,
                64,
                Self.reportCallback,
                context
            )
            IOHIDDeviceScheduleWithRunLoop(
                device,
                CFRunLoopGetCurrent(),
                CFRunLoopMode.defaultMode.rawValue
            )
        }

        func close() {
            IOHIDDeviceUnscheduleFromRunLoop(
                device,
                CFRunLoopGetCurrent(),
                CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            reportBuffer.deinitialize(count: 64)
            reportBuffer.deallocate()
        }

        func featureIndex(_ featureID: UInt16) -> UInt8? {
            guard let response = request(
                featureIndex: 0,
                function: 0,
                parameters: [UInt8(featureID >> 8), UInt8(featureID & 0xff)]
            ), response.count > 4 else { return nil }
            return response[4]
        }

        func request(
            featureIndex: UInt8,
            function: UInt8,
            parameters: [UInt8] = []
        ) -> [UInt8]? {
            let functionAndSoftwareID = (function << 4) | Self.softwareID
            receiver.response = nil
            receiver.expectedFeature = featureIndex
            receiver.expectedFunction = functionAndSoftwareID
            defer {
                receiver.expectedFeature = nil
                receiver.expectedFunction = nil
            }
            var report = [UInt8](repeating: 0, count: 20)
            report[0] = 0x11
            report[1] = 0xff
            report[2] = featureIndex
            report[3] = functionAndSoftwareID
            for (offset, value) in parameters.prefix(16).enumerated() {
                report[4 + offset] = value
            }

            let result = report.withUnsafeMutableBytes { bytes in
                IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeOutput,
                    CFIndex(0x11),
                    bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    bytes.count
                )
            }
            guard result == kIOReturnSuccess else { return nil }

            let deadline = Date().addingTimeInterval(0.6)
            while receiver.response == nil, Date() < deadline {
                CFRunLoopRunInMode(.defaultMode, 0.05, true)
            }
            return receiver.response
        }

        private static let reportCallback: IOHIDReportCallback = {
            context, _, _, _, reportID, report, reportLength in
            guard reportID == 0x11, let context else { return }
            let receiver = Unmanaged<Receiver>.fromOpaque(context).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
            guard bytes.count > 3,
                  bytes[2] == receiver.expectedFeature,
                  bytes[3] == receiver.expectedFunction else { return }
            receiver.response = bytes
        }
    }
}
