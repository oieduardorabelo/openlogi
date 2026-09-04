import Combine
import ServiceManagement
import XCTest
@testable import OpenLogi

final class ShortcutTests: XCTestCase {
    @MainActor
    func testInputActivityDeduplicatesRepeatedKey() {
        let activity = KeyboardInputActivity()
        var updateCount = 0
        let observation = activity.objectWillChange.sink {
            updateCount += 1
        }

        activity.record(.keyboard(0))
        activity.record(.keyboard(0))

        XCTAssertEqual(updateCount, 1)
        withExtendedLifetime(observation) {}
    }

    func testEventWorkerCapturesOnceAndResetsInputAfterRelease() {
        let worker = KeyboardEventWorker()
        let inputs = expectation(description: "distinct key presses")
        inputs.expectedFulfillmentCount = 2
        let capture = expectation(description: "single capture")

        worker.setHandlers(
            onInput: { _ in inputs.fulfill() },
            onCapture: { token, _ in
                if token == 7 { capture.fulfill() }
            }
        )
        worker.beginCapture(token: 7)
        worker.handleLogitechFunctionKey(keyCode: 118, isDown: true, modifiers: [])
        worker.handleLogitechFunctionKey(keyCode: 118, isDown: true, modifiers: [])
        worker.handleLogitechFunctionKey(keyCode: 118, isDown: false, modifiers: [])
        worker.handleLogitechFunctionKey(keyCode: 118, isDown: true, modifiers: [])

        wait(for: [inputs, capture], timeout: 0.1)
    }

    func testEventWorkerCancellationPreventsCapture() {
        let worker = KeyboardEventWorker()
        let capture = expectation(description: "cancelled capture")
        capture.isInverted = true
        worker.setHandlers(onInput: { _ in }, onCapture: { _, _ in capture.fulfill() })

        worker.beginCapture(token: 1)
        worker.cancelCapture(token: 1)
        worker.handleLogitechFunctionKey(keyCode: 118, isDown: true, modifiers: [])

        wait(for: [capture], timeout: 0.02)
    }

    func testMediaKeyParsingDoesNotRequireNSEvent() {
        let keyCode = 16
        let down = KeyboardEventWorker.parseMediaKey(
            subtype: 8,
            data1: Int64((keyCode << 16) | (0x0a << 8))
        )
        let up = KeyboardEventWorker.parseMediaKey(
            subtype: 8,
            data1: Int64((keyCode << 16) | (0x0b << 8))
        )
        let repeatedDown = KeyboardEventWorker.parseMediaKey(
            subtype: 8,
            data1: Int64((keyCode << 16) | (0x0a << 8) | 0x1)
        )

        XCTAssertEqual(down?.stroke, .media(keyCode))
        XCTAssertEqual(down?.isDown, true)
        XCTAssertEqual(down?.isRepeat, false)
        XCTAssertEqual(up?.stroke, .media(keyCode))
        XCTAssertEqual(up?.isDown, false)
        XCTAssertEqual(repeatedDown?.stroke, .media(keyCode))
        XCTAssertEqual(repeatedDown?.isDown, true)
        XCTAssertEqual(repeatedDown?.isRepeat, true)
        XCTAssertNil(KeyboardEventWorker.parseMediaKey(subtype: 7, data1: 0))
        XCTAssertNil(KeyboardEventWorker.parseMediaKey(subtype: 8, data1: 0))
    }

    func testKeyboardDisplayName() {
        let stroke = KeyStroke.keyboard(8, modifiers: [.command, .shift])
        XCTAssertEqual(stroke.displayName, "⇧⌘C")
    }

    func testFunctionFlagIsNormalizedForFunctionKeyInput() {
        let plainF4 = KeyStroke.keyboard(118)
        let functionF4 = KeyStroke.keyboard(118, modifiers: .function)
        XCTAssertEqual(functionF4.displayName, "Standard F4")
        XCTAssertEqual(functionF4.normalizedForInputMatching, plainF4)
    }

    func testLogitechBareF4LaunchpadSignalMatchesF4() {
        XCTAssertEqual(
            KeyStroke.media(13).normalizedForInputMatching,
            KeyStroke.logitechFunction(118)
        )
    }

    func testFunctionKeySourcesHaveDistinctLabelsAndMatching() {
        let standardF4 = KeyStroke.keyboard(118)
        let logitechF4 = KeyStroke.logitechFunction(118)
        XCTAssertEqual(standardF4.displayName, "Standard F4")
        XCTAssertEqual(logitechF4.displayName, "Logi F4")
        XCTAssertNotEqual(standardF4.normalizedForInputMatching, logitechF4.normalizedForInputMatching)
    }

    func testLogitechModifiersAreIgnoredForInputMatching() {
        let shiftedF4 = KeyStroke.logitechFunction(118, modifiers: [.shift, .function])

        XCTAssertEqual(shiftedF4.displayName, "Logi F4")
        XCTAssertEqual(shiftedF4.normalizedForInputMatching, .logitechFunction(118))
    }

    func testLogitechOutputNormalizesToStandardFunctionKey() {
        let captured = KeyStroke.logitechFunction(118, modifiers: [.shift, .function])

        XCTAssertEqual(
            captured.normalizedForOutput,
            .keyboard(118, modifiers: .shift)
        )
        XCTAssertEqual(
            ShortcutRule(output: captured).targetDisplayName,
            "⇧Standard F4"
        )
    }

    func testEventWorkerMatchesModifierVariantForDivertedLogitechKey() {
        let rule = ShortcutRule(
            input: .logitechFunction(118),
            output: .keyboard(0),
            isEnabled: true
        )
        let executed = expectation(description: "diverted Logitech rule executes")
        let worker = KeyboardEventWorker { executedRule in
            XCTAssertEqual(executedRule, rule)
            executed.fulfill()
        }
        worker.update(rules: [rule], isEnabled: true)

        worker.handleLogitechFunctionKey(
            keyCode: 118,
            isDown: true,
            modifiers: [.shift, .option]
        )

        wait(for: [executed], timeout: 0.1)
    }

    func testLogitechFnStateParsing() {
        XCTAssertEqual(
            LogitechFnHID.parseStandardFKeys(
                response: [0x11, 0xff, 0x0c, 0x0a, 0x00, 0x01],
                hostPrefixed: true
            ),
            false
        )
        XCTAssertEqual(
            LogitechFnHID.parseStandardFKeys(
                response: [0x11, 0xff, 0x0c, 0x0a, 0x00],
                hostPrefixed: false
            ),
            true
        )
    }

    func testLogitechF4ControlParsing() {
        let response: [UInt8] = [
            0x11, 0xff, 0x08, 0x1b,
            0x00, 0xe2, 0x00, 0xc1, 0x3a, 0x04, 0x00, 0x00, 0x04
        ]
        XCTAssertEqual(
            LogitechFunctionKeyHID.parseControl(response: response),
            .init(controlID: 0x00e2, position: 4, isDivertable: true)
        )
        XCTAssertEqual(LogitechFunctionKeyHID.keyCode(forPosition: 4), 118)
        XCTAssertEqual(LogitechFunctionKeyHID.position(forKeyCode: 118), 4)
    }

    func testLogitechDivertedControlReportParsing() {
        XCTAssertEqual(
            LogitechFunctionKeyHID.parsePressedControlIDs(
                report: [0x11, 0xff, 0x08, 0x00, 0x00, 0xe2, 0x00, 0x00]
            ),
            [0x00e2]
        )
        XCTAssertTrue(
            LogitechFunctionKeyHID.parsePressedControlIDs(
                report: [0x11, 0xff, 0x08, 0x00, 0x00, 0x00]
            ).isEmpty
        )
    }

    func testShortcutRoundTrip() throws {
        let rule = ShortcutRule(
            name: "Copy with F1",
            input: .keyboard(122),
            output: .keyboard(8, modifiers: .command),
            isEnabled: true
        )
        let data = try JSONEncoder().encode(rule)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutRule.self, from: data), rule)
    }

    func testSystemActionRoundTrip() throws {
        let rule = ShortcutRule(
            name: "Mission Control",
            input: .keyboard(118),
            systemAction: .missionControl,
            isEnabled: true
        )
        let data = try JSONEncoder().encode(rule)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutRule.self, from: data), rule)
        XCTAssertEqual(rule.targetDisplayName, "Mission Control")
    }

    func testMissionControlUsesDirectSystemAction() {
        XCTAssertNil(SystemAction.missionControl.shortcut)
    }

    func testNewRulesDefaultToDisabled() {
        XCTAssertFalse(ShortcutRule().isEnabled)
    }

    func testEverySystemActionHasAGroup() {
        let grouped = Set(SystemActionGroup.allCases.flatMap { group in
            SystemAction.allCases.filter { $0.group == group }
        })
        XCTAssertEqual(grouped, Set(SystemAction.allCases))
    }

    @MainActor
    func testStoreMatchesEnabledRule() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ShortcutStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
        let rule = ShortcutRule(input: .keyboard(0), output: .keyboard(11), isEnabled: true)
        store.rules = [rule]
        XCTAssertEqual(store.rule(for: .keyboard(0)), rule)
        XCTAssertNil(store.rule(for: .keyboard(1)))
    }

    @MainActor
    func testStorePreservesFirstEnabledRulePrecedence() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ShortcutStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
        let disabled = ShortcutRule(input: .keyboard(0), output: .keyboard(1), isEnabled: false)
        let first = ShortcutRule(input: .keyboard(0), output: .keyboard(2), isEnabled: true)
        let second = ShortcutRule(input: .keyboard(0), output: .keyboard(3), isEnabled: true)

        store.rules = [disabled, first, second]

        XCTAssertEqual(store.rule(for: .keyboard(0)), first)
        store.rules[1].isEnabled = false
        XCTAssertEqual(store.rule(for: .keyboard(0)), second)
    }

    @MainActor
    func testStoreLookupReturnsLatestNonTopologyEdits() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ShortcutStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
        store.rules = [ShortcutRule(
            name: "Before",
            input: .keyboard(0),
            output: .keyboard(1),
            isEnabled: true
        )]

        store.rules[0].name = "After"
        store.rules[0].output = .keyboard(2)

        XCTAssertEqual(store.rule(for: .keyboard(0))?.name, "After")
        XCTAssertEqual(store.rule(for: .keyboard(0))?.output, .keyboard(2))
    }

    @MainActor
    func testDuplicateLookupUsesNormalizedEnabledInputs() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ShortcutStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
        let first = ShortcutRule(input: .keyboard(118), isEnabled: true)
        let duplicate = ShortcutRule(
            input: .keyboard(118, modifiers: .function),
            isEnabled: true
        )
        let disabledDuplicate = ShortcutRule(input: .keyboard(118), isEnabled: false)
        store.rules = [first, duplicate, disabledDuplicate]

        XCTAssertTrue(store.isDuplicate(first))
        XCTAssertTrue(store.isDuplicate(duplicate))
        XCTAssertFalse(store.isDuplicate(disabledDuplicate))

        store.rules = [first, disabledDuplicate]
        XCTAssertFalse(store.isDuplicate(first))
    }

    @MainActor
    func testStoreFlushPersistsLatestCoalescedState() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("shortcuts.json")
        let store = ShortcutStore(fileURL: fileURL)
        store.rules = [ShortcutRule(name: "Superseded")]
        let latest = ShortcutRule(name: "Latest", input: .keyboard(2), output: .keyboard(3))
        store.rules = [latest]
        store.isEnabled = false

        store.flush()

        let reloaded = ShortcutStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.rules, [latest])
        XCTAssertFalse(reloaded.isEnabled)
    }

    @MainActor
    func testStoreMatchesF4RegardlessOfFunctionFlag() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ShortcutStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
        let rule = ShortcutRule(
            input: .keyboard(118),
            systemAction: .missionControl,
            isEnabled: true
        )
        store.rules = [rule]
        XCTAssertEqual(store.rule(for: .keyboard(118, modifiers: .function)), rule)
    }

    @MainActor
    func testAddingRulePreservesMasterSwitchAndStartsDisabled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ShortcutStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
        store.isEnabled = false
        store.addRule()
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(store.rules[0].isEnabled)
    }

    @MainActor
    func testMissionControlPresetUsesLogitechF4() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ShortcutStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
        store.addMissionControlRule()
        XCTAssertEqual(store.rules[0].input, .logitechFunction(118))
    }

    @MainActor
    func testLegacyFunctionRulesMigrateToLogitechLabels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("shortcuts.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
        {
          "isEnabled": true,
          "rules": [{
            "id": "9162C242-48A7-40EE-A0DB-D28BFAD65BB9",
            "input": {"keyCode": 118, "kind": "keyboard", "modifiers": 0},
            "isEnabled": true,
            "name": "Mission Control",
            "output": {"keyCode": 11, "kind": "keyboard", "modifiers": 0},
            "systemAction": "missionControl"
          }]
        }
        """
        try Data(legacy.utf8).write(to: fileURL)

        let store = ShortcutStore(fileURL: fileURL)
        XCTAssertEqual(store.rules[0].input.kind, .logitechFunction)
        XCTAssertEqual(store.rules[0].input.displayName, "Logi F4")
        XCTAssertTrue(try String(contentsOf: fileURL).contains("\"schemaVersion\" : 3"))
    }

    @MainActor
    func testVersionTwoLogitechOutputsMigrateToStandardFunctionKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("shortcuts.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let versionTwo = """
        {
          "schemaVersion": 2,
          "isEnabled": true,
          "rules": [{
            "id": "9162C242-48A7-40EE-A0DB-D28BFAD65BB9",
            "input": {"keyCode": 118, "kind": "logitechFunction", "modifiers": 8},
            "isEnabled": true,
            "name": "Logitech target",
            "output": {"keyCode": 118, "kind": "logitechFunction", "modifiers": 24}
          }]
        }
        """
        try Data(versionTwo.utf8).write(to: fileURL)

        let store = ShortcutStore(fileURL: fileURL)

        XCTAssertEqual(store.rules[0].input, .logitechFunction(118))
        XCTAssertEqual(store.rules[0].output, .keyboard(118, modifiers: .shift))
        XCTAssertTrue(try String(contentsOf: fileURL).contains("\"schemaVersion\" : 3"))
    }

    @MainActor
    func testUnreadableConfigurationIsPreservedBeforeReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("shortcuts.json")
        let corruptData = Data("not valid json".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try corruptData.write(to: fileURL)

        let store = ShortcutStore(fileURL: fileURL)

        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertNotNil(store.persistenceError)
        let recoveryURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(recoveryURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: recoveryURLs[0]), corruptData)

        store.addRule()
        store.flush()

        let reloaded = ShortcutStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.rules.count, 1)
        XCTAssertNil(reloaded.persistenceError)
        XCTAssertEqual(try Data(contentsOf: recoveryURLs[0]), corruptData)
    }

    @MainActor
    func testSavingKeepsPreviousConfigurationBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("shortcuts.json")
        let store = ShortcutStore(fileURL: fileURL)
        store.rules = [ShortcutRule(name: "Previous")]
        store.flush()
        store.rules[0].name = "Current"
        store.flush()

        let backup = try String(contentsOf: fileURL.appendingPathExtension("backup"))
        XCTAssertTrue(backup.contains("Previous"))
        XCTAssertFalse(backup.contains("Current"))
    }

    @MainActor
    func testCorruptPrimaryDoesNotOverwriteKnownGoodBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("shortcuts.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        let store = ShortcutStore(fileURL: fileURL)
        store.rules = [ShortcutRule(name: "Known good")]
        store.flush()
        store.rules[0].name = "Latest good"
        store.flush()
        let knownGoodBackup = try Data(contentsOf: backupURL)

        try Data("damaged primary".utf8).write(to: fileURL)
        let recoveringStore = ShortcutStore(fileURL: fileURL)
        recoveringStore.addRule()
        recoveringStore.flush()

        XCTAssertEqual(try Data(contentsOf: backupURL), knownGoodBackup)
        XCTAssertNotNil(recoveringStore.persistenceError)
    }

    @MainActor
    func testPermissionStatusNamesEveryMissingPermission() {
        let status = KeyboardEngine.Status.permissionRequired([.accessibility, .inputMonitoring])
        XCTAssertEqual(
            status.label,
            "Accessibility and Input Monitoring permissions required"
        )
    }

    @MainActor
    func testLaunchAtLoginStateMapping() {
        XCTAssertEqual(
            LaunchAtLoginController.state(for: .notRegistered),
            .disabled
        )
        XCTAssertEqual(
            LaunchAtLoginController.state(for: .enabled),
            .enabled
        )
        XCTAssertEqual(
            LaunchAtLoginController.state(for: .requiresApproval),
            .requiresApproval
        )
        XCTAssertEqual(
            LaunchAtLoginController.state(for: .notFound),
            .disabled
        )
    }

    @MainActor
    func testLaunchAtLoginControllerRegistersAndUnregisters() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.registerCount, 1)

        controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    @MainActor
    func testLaunchAtLoginControllerRegistersFromNotFound() {
        let service = FakeLaunchAtLoginService(status: .notFound)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertTrue(controller.canToggle)
        XCTAssertFalse(controller.isEnabled)

        controller.setEnabled(true)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.registerCount, 1)
    }

    @MainActor
    func testLaunchAtLoginApprovalRemainsRegistered() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
        XCTAssertNotNil(controller.notice)
    }

    @MainActor
    func testLaunchAtLoginControllerSurfacesRegistrationFailure() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registrationError = NSError(
            domain: "LaunchAtLoginTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "test failure"]
        )
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(
            controller.errorMessage,
            "Could not enable Start at Login: test failure"
        )
    }
}

private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: SMAppService.Status
    var registrationError: Error?
    var unregistrationError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registrationError { throw registrationError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }
}
