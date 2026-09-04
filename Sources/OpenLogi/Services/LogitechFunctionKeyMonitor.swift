import Foundation
import IOKit.hid

final class LogitechFunctionKeyMonitor: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case inactive
        case connecting
        case active(deviceName: String)
        case unavailable(String)
    }

    private let commandQueue = DispatchQueue(
        label: "com.openlogi.logitech-function-keys",
        qos: .userInitiated
    )
    private let onKey: @Sendable (Int, Bool) -> Void
    private let onStatus: @Sendable (Status) -> Void
    private var watcher: LogitechKeyboardWatcher?
    private var session: Session?
    private var nextSessionGeneration: UInt64 = 0
    private var activeSessionGeneration: UInt64?
    private var featureIndex: UInt8?
    private var controlsByPosition: [Int: UInt16] = [:]
    private var positionsByControl: [UInt16: Int] = [:]
    private var divertedControlIDs = Set<UInt16>()
    private var pressedControlIDs = Set<UInt16>()
    private var requiredPositions = Set<Int>()
    private var captureAll = false
    private var isStopped = false
    private var status: Status = .inactive

    init(
        onKey: @escaping @Sendable (Int, Bool) -> Void,
        onStatus: @escaping @Sendable (Status) -> Void = { _ in }
    ) {
        self.onKey = onKey
        self.onStatus = onStatus
        watcher = LogitechKeyboardWatcher { [weak self] change in
            guard let self else { return }
            commandQueue.async { [weak self] in
                self?.handleDeviceChange(change)
            }
        }
    }

    func update(requiredPositions: Set<Int>, captureAll: Bool) {
        commandQueue.async { [weak self] in
            self?.updateOnQueue(requiredPositions: requiredPositions, captureAll: captureAll)
        }
    }

    func refresh() {
        commandQueue.async { [weak self] in
            self?.refreshOnQueue()
        }
    }

    func stop() {
        commandQueue.sync { [self] in
            guard !isStopped else { return }
            isStopped = true
            stopSession(restoringDiversions: true)
            setStatus(.inactive)
        }
        watcher?.close()
        watcher = nil
    }

    private func updateOnQueue(requiredPositions: Set<Int>, captureAll: Bool) {
        guard !isStopped else { return }
        self.requiredPositions = requiredPositions
        self.captureAll = captureAll

        guard !requiredPositions.isEmpty || captureAll else {
            stopSession(restoringDiversions: true)
            setStatus(.inactive)
            return
        }
        startIfNeeded()
        applyDiversions()
    }

    private func refreshOnQueue() {
        guard !isStopped, !requiredPositions.isEmpty || captureAll else { return }
        if let session, let featureIndex,
           session.request(featureIndex: featureIndex, function: 0) == nil {
            stopSession(restoringDiversions: false)
        }
        if session == nil { startIfNeeded() }
        applyDiversions()
    }

    private func handleDeviceChange(_ change: LogitechKeyboardWatcher.Change) {
        guard !isStopped, !requiredPositions.isEmpty || captureAll else { return }
        switch change {
        case .matched:
            if session == nil {
                startIfNeeded()
                applyDiversions()
            }
        case .removed:
            stopSession(restoringDiversions: false)
            startIfNeeded()
            applyDiversions()
        }
    }

    private func startIfNeeded() {
        guard session == nil else { return }
        setStatus(.connecting)
        let devices = Session.matchingDevices()
        for device in devices {
            nextSessionGeneration &+= 1
            let generation = nextSessionGeneration
            guard let candidate = Session(device: device, onReport: { [weak self] report in
                guard let self else { return }
                commandQueue.async { [weak self] in
                    self?.handle(report: report, generation: generation)
                }
            }) else { continue }
            guard let discovery = discoverControls(in: candidate) else {
                candidate.close()
                continue
            }

            session = candidate
            activeSessionGeneration = generation
            featureIndex = discovery.featureIndex
            controlsByPosition = discovery.controls
            positionsByControl = Dictionary(
                uniqueKeysWithValues: discovery.controls.map { ($0.value, $0.key) }
            )
            setStatus(.active(deviceName: candidate.deviceName))
            return
        }
        let message = devices.isEmpty
            ? "Logitech keyboard not connected or accessible"
            : "Connected Logitech keyboard does not support direct F-key remapping"
        setStatus(.unavailable(message))
    }

    private func discoverControls(in session: Session) -> (featureIndex: UInt8, controls: [Int: UInt16])? {
        guard let featureIndex = session.featureIndex(0x1b04), featureIndex != 0,
              let countResponse = session.request(featureIndex: featureIndex, function: 0),
              countResponse.count > 4 else { return nil }

        var controls: [Int: UInt16] = [:]
        for index in 0..<Int(countResponse[4]) {
            guard let response = session.request(
                featureIndex: featureIndex,
                function: 1,
                parameters: [UInt8(index)]
            ),
            let control = LogitechFunctionKeyHID.parseControl(response: response),
            control.isDivertable,
            (1...12).contains(control.position) else { continue }
            controls[control.position] = control.controlID
        }
        return controls.isEmpty ? nil : (featureIndex, controls)
    }

    private func applyDiversions() {
        guard let session, let featureIndex else { return }
        let desiredPositions = captureAll ? Set(controlsByPosition.keys) : requiredPositions
        let unavailablePositions = desiredPositions.subtracting(controlsByPosition.keys)
        let desiredControlIDs = Set(desiredPositions.compactMap { controlsByPosition[$0] })

        removeDiversions(
            divertedControlIDs.subtracting(desiredControlIDs),
            featureIndex: featureIndex,
            session: session
        )
        addDiversions(
            desiredControlIDs.subtracting(divertedControlIDs),
            featureIndex: featureIndex,
            session: session
        )
        reportDiversionStatus(
            desiredControlIDs: desiredControlIDs,
            unavailablePositions: unavailablePositions,
            deviceName: session.deviceName
        )
    }

    private func removeDiversions(
        _ controlIDs: Set<UInt16>,
        featureIndex: UInt8,
        session: Session
    ) {
        for controlID in controlIDs {
            if setDiverted(false, controlID: controlID, featureIndex: featureIndex, session: session) {
                divertedControlIDs.remove(controlID)
            }
        }
    }

    private func addDiversions(
        _ controlIDs: Set<UInt16>,
        featureIndex: UInt8,
        session: Session
    ) {
        for controlID in controlIDs {
            if setDiverted(true, controlID: controlID, featureIndex: featureIndex, session: session) {
                divertedControlIDs.insert(controlID)
            }
        }
    }

    private func reportDiversionStatus(
        desiredControlIDs: Set<UInt16>,
        unavailablePositions: Set<Int>,
        deviceName: String
    ) {
        if !unavailablePositions.isEmpty {
            let keys = unavailablePositions.sorted().map { "F\($0)" }.joined(separator: ", ")
            setStatus(.unavailable("Direct remapping is unavailable for \(keys) on this keyboard"))
        } else if divertedControlIDs.isSuperset(of: desiredControlIDs) {
            setStatus(.active(deviceName: deviceName))
        } else {
            setStatus(.unavailable("Could not enable direct Logitech F-key access"))
        }
    }

    private func setDiverted(
        _ diverted: Bool,
        controlID: UInt16,
        featureIndex: UInt8,
        session: Session
    ) -> Bool {
        let flag: UInt8 = diverted ? 0x03 : 0x02
        return session.request(
            featureIndex: featureIndex,
            function: 3,
            parameters: [UInt8(controlID >> 8), UInt8(controlID & 0xff), flag, 0, 0]
        ) != nil
    }

    private func stopSession(restoringDiversions: Bool) {
        if restoringDiversions, let session, let featureIndex {
            for controlID in divertedControlIDs {
                _ = setDiverted(false, controlID: controlID, featureIndex: featureIndex, session: session)
            }
        }
        for controlID in pressedControlIDs {
            guard let position = positionsByControl[controlID],
                  let keyCode = LogitechFunctionKeyHID.keyCode(forPosition: position) else { continue }
            onKey(keyCode, false)
        }
        divertedControlIDs.removeAll(keepingCapacity: true)
        pressedControlIDs.removeAll(keepingCapacity: true)
        activeSessionGeneration = nil
        session?.close()
        session = nil
        featureIndex = nil
        controlsByPosition.removeAll(keepingCapacity: true)
        positionsByControl.removeAll(keepingCapacity: true)
    }

    private func handle(report: [UInt8], generation: UInt64) {
        guard activeSessionGeneration == generation,
              let featureIndex,
              report.count >= 4,
              report[2] == featureIndex,
              report[3] == 0 else { return }

        let current = LogitechFunctionKeyHID.parsePressedControlIDs(report: report)
        for controlID in current.subtracting(pressedControlIDs) {
            guard let position = positionsByControl[controlID],
                  let keyCode = LogitechFunctionKeyHID.keyCode(forPosition: position) else { continue }
            onKey(keyCode, true)
        }
        for controlID in pressedControlIDs.subtracting(current) {
            guard let position = positionsByControl[controlID],
                  let keyCode = LogitechFunctionKeyHID.keyCode(forPosition: position) else { continue }
            onKey(keyCode, false)
        }
        pressedControlIDs = current
    }

    private func setStatus(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
        onStatus(newStatus)
    }

    private final class Receiver: @unchecked Sendable {
        private let condition = NSCondition()
        private var response: [UInt8]?
        private var expectedFeature: UInt8?
        private var expectedFunction: UInt8?
        private let onReport: @Sendable ([UInt8]) -> Void

        init(onReport: @escaping @Sendable ([UInt8]) -> Void) {
            self.onReport = onReport
        }

        func prepare(feature: UInt8, function: UInt8) {
            condition.lock()
            response = nil
            expectedFeature = feature
            expectedFunction = function
            condition.unlock()
        }

        func cancelRequest() {
            condition.lock()
            expectedFeature = nil
            expectedFunction = nil
            response = nil
            condition.broadcast()
            condition.unlock()
        }

        func waitForResponse(timeout: TimeInterval) -> [UInt8]? {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            while response == nil, expectedFeature != nil, Date() < deadline {
                _ = condition.wait(until: deadline)
            }
            let response = self.response
            expectedFeature = nil
            expectedFunction = nil
            self.response = nil
            condition.unlock()
            return response
        }

        func receive(_ bytes: [UInt8]) {
            condition.lock()
            let matchesRequest = bytes.count > 3
                && bytes[2] == expectedFeature
                && bytes[3] == expectedFunction
            if matchesRequest {
                response = bytes
                condition.broadcast()
            }
            let isKeyReport = bytes.count > 3 && bytes[3] == 0
            condition.unlock()

            if isKeyReport { onReport(bytes) }
        }
    }

    private final class Session {
        private static let softwareID: UInt8 = 0x0b
        private let device: IOHIDDevice
        private let receiver: Receiver
        private let reportBuffer: UnsafeMutablePointer<UInt8>
        private let reportQueue = DispatchQueue(
            label: "com.openlogi.logitech-function-key-reports",
            qos: .userInteractive
        )
        private let cancellation = DispatchSemaphore(value: 0)
        private var isClosed = false
        let deviceName: String

        static func matchingDevices() -> [IOHIDDevice] {
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(manager, LogitechKeyboardWatcher.matching as CFDictionary)
            guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                return []
            }
            let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>).map(Array.init) ?? []
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return devices
        }

        init?(device: IOHIDDevice, onReport: @escaping @Sendable ([UInt8]) -> Void) {
            receiver = Receiver(onReport: onReport)
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                return nil
            }
            self.device = device
            deviceName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
                ?? "Logitech keyboard"
            reportBuffer = .allocate(capacity: 64)
            reportBuffer.initialize(repeating: 0, count: 64)

            IOHIDDeviceRegisterInputReportCallback(
                device,
                reportBuffer,
                64,
                Self.reportCallback,
                Unmanaged.passUnretained(receiver).toOpaque()
            )
            IOHIDDeviceSetDispatchQueue(device, reportQueue)
            IOHIDDeviceSetCancelHandler(device) { [cancellation] in
                cancellation.signal()
            }
            IOHIDDeviceActivate(device)
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            IOHIDDeviceCancel(device)
            cancellation.wait()
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            reportBuffer.deinitialize(count: 64)
            reportBuffer.deallocate()
        }

        deinit {
            close()
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
            receiver.prepare(feature: featureIndex, function: functionAndSoftwareID)

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
                    0x11,
                    bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    bytes.count
                )
            }
            guard result == kIOReturnSuccess else {
                receiver.cancelRequest()
                return nil
            }
            return receiver.waitForResponse(timeout: 0.6)
        }

        private static let reportCallback: IOHIDReportCallback = {
            context, _, _, _, reportID, report, reportLength in
            guard reportID == 0x11, let context else { return }
            let receiver = Unmanaged<Receiver>.fromOpaque(context).takeUnretainedValue()
            receiver.receive(Array(UnsafeBufferPointer(start: report, count: reportLength)))
        }
    }
}

final class LogitechKeyboardWatcher: @unchecked Sendable {
    enum Change: Sendable {
        case matched
        case removed
    }

    static let matching: [String: Int] = [
        kIOHIDVendorIDKey: 0x046d,
        kIOHIDPrimaryUsagePageKey: 1,
        kIOHIDPrimaryUsageKey: 6
    ]

    private final class Receiver: @unchecked Sendable {
        let onChange: @Sendable (Change) -> Void

        init(onChange: @escaping @Sendable (Change) -> Void) {
            self.onChange = onChange
        }
    }

    private let manager: IOHIDManager
    private let receiver: Receiver
    private let queue = DispatchQueue(label: "com.openlogi.logitech-device-watcher", qos: .utility)
    private let cancellation = DispatchSemaphore(value: 0)
    private let closeLock = NSLock()
    private var isClosed = false
    private var isActivated = false

    init?(onChange: @escaping @Sendable (Change) -> Void) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        receiver = Receiver(onChange: onChange)
        IOHIDManagerSetDeviceMatching(manager, Self.matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            // A failable initializer still runs deinit after stored properties
            // are initialized. Mark this closed so deinit cannot wait for a
            // cancellation handler from a manager that was never activated.
            isClosed = true
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return nil
        }
        let context = Unmanaged.passUnretained(receiver).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.matchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.removedCallback, context)
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerSetCancelHandler(manager) { [cancellation] in
            cancellation.signal()
        }
        IOHIDManagerActivate(manager)
        isActivated = true
    }

    func close() {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        isClosed = true
        let shouldWaitForCancellation = isActivated
        isActivated = false
        closeLock.unlock()

        if shouldWaitForCancellation {
            IOHIDManagerCancel(manager)
            cancellation.wait()
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        close()
    }

    private static let matchedCallback: IOHIDDeviceCallback = { context, _, _, _ in
        guard let context else { return }
        let receiver = Unmanaged<Receiver>.fromOpaque(context).takeUnretainedValue()
        receiver.onChange(.matched)
    }

    private static let removedCallback: IOHIDDeviceCallback = { context, _, _, _ in
        guard let context else { return }
        let receiver = Unmanaged<Receiver>.fromOpaque(context).takeUnretainedValue()
        receiver.onChange(.removed)
    }
}

enum LogitechFunctionKeyHID {
    struct Control: Equatable {
        let controlID: UInt16
        let position: Int
        let isDivertable: Bool
    }

    private static let keyCodeByPosition: [Int: Int] = [
        1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97,
        7: 98, 8: 100, 9: 101, 10: 109, 11: 103, 12: 111
    ]
    private static let positionByKeyCode = Dictionary(
        uniqueKeysWithValues: keyCodeByPosition.map { ($0.value, $0.key) }
    )

    static func parseControl(response: [UInt8]) -> Control? {
        guard response.count > 12 else { return nil }
        let controlID = UInt16(response[4]) << 8 | UInt16(response[5])
        let flags = UInt16(response[8]) | UInt16(response[12]) << 8
        return Control(
            controlID: controlID,
            position: Int(response[9]),
            isDivertable: flags & 0x20 != 0
        )
    }

    static func parsePressedControlIDs(report: [UInt8]) -> Set<UInt16> {
        guard report.count > 5 else { return [] }
        var result = Set<UInt16>()
        var index = 4
        while index + 1 < report.count {
            let controlID = UInt16(report[index]) << 8 | UInt16(report[index + 1])
            if controlID != 0 { result.insert(controlID) }
            index += 2
        }
        return result
    }

    static func keyCode(forPosition position: Int) -> Int? {
        keyCodeByPosition[position]
    }

    static func position(forKeyCode keyCode: Int) -> Int? {
        positionByKeyCode[keyCode]
    }
}
