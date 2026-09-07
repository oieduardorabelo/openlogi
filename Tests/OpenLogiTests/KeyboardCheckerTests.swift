import CoreGraphics
import XCTest
@testable import OpenLogi

final class KeyboardCheckerTests: XCTestCase {
    @MainActor
    func testDeletedRowBindingCanFinishEditingWithoutRestoringRule() {
        let store = makeStore()
        let rule = ShortcutRule(name: "Delete while editing")
        store.rules = [rule]
        let binding = store.binding(for: rule)

        store.removeRule(id: rule.id)
        XCTAssertEqual(binding.wrappedValue.id, rule.id)
        binding.name.wrappedValue = "Late text-field commit"

        XCTAssertTrue(store.rules.isEmpty)
    }

    @MainActor
    func testRowBindingFollowsIdentityAfterEarlierRowIsRemoved() {
        let store = makeStore()
        let first = ShortcutRule(name: "First")
        let second = ShortcutRule(name: "Second")
        store.rules = [first, second]
        let binding = store.binding(for: second)

        store.removeRule(id: first.id)
        binding.name.wrappedValue = "Still the second rule"

        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules.first?.id, second.id)
        XCTAssertEqual(store.rules.first?.name, "Still the second rule")
    }

    @MainActor
    func testHistoryTracksRepeatReleaseAndHasBoundedSize() {
        let checker = KeyboardChecker()
        checker.record(.init(stroke: .keyboard(0, modifiers: .shift), phase: .pressed))
        checker.record(.init(stroke: .keyboard(0, modifiers: .shift), phase: .repeated))
        XCTAssertEqual(checker.heldKeys, [.keyboard(0)])
        XCTAssertEqual(checker.modifiers, .shift)

        // Releasing Shift before A must still clear the same physical key.
        checker.record(.init(stroke: .keyboard(0), phase: .released))
        XCTAssertTrue(checker.heldKeys.isEmpty)
        for _ in 0..<120 {
            checker.record(.init(stroke: .keyboard(1), phase: .pressed))
        }
        XCTAssertEqual(checker.events.count, 100)
        checker.clearHistory()
        XCTAssertTrue(checker.events.isEmpty)
        XCTAssertEqual(checker.heldKeys, [.keyboard(1)])
        checker.resetHeldKeys()
        XCTAssertTrue(checker.heldKeys.isEmpty)
    }

    func testCheckerCapturesEveryKeyEventAndRestoresRemapping() throws {
        let executed = expectation(description: "remapping resumes after checker")
        executed.assertForOverFulfill = true
        let worker = KeyboardEventWorker { _ in executed.fulfill() }
        worker.update(rules: [ShortcutRule(input: .keyboard(0), isEnabled: true)], isEnabled: true)
        let recorded = EventRecorder()
        worker.setCheckHandler { recorded.append($0) }

        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
        XCTAssertNil(worker.handle(type: .keyDown, event: down))
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertNil(worker.handle(type: .keyDown, event: down))
        XCTAssertNil(worker.handle(type: .keyUp, event: up))
        XCTAssertEqual(recorded.events.map(\.phase), [.pressed, .repeated, .released])

        worker.setCheckHandler(nil)
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        XCTAssertNil(worker.handle(type: .keyDown, event: down))
        wait(for: [executed], timeout: 0.1)
    }

    func testCheckerObservesModifiersAndLogitechKeysAndIgnoresSyntheticEvents() throws {
        let worker = KeyboardEventWorker()
        let recorded = EventRecorder()
        worker.setCheckHandler { recorded.append($0) }
        let flags = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true))
        flags.flags = [.maskShift, .maskAlphaShift]
        XCTAssertNotNil(worker.handle(type: .flagsChanged, event: flags))
        worker.handleLogitechFunctionKey(keyCode: 118, isDown: true, modifiers: .shift)
        worker.handleLogitechFunctionKey(keyCode: 118, isDown: false, modifiers: [])
        flags.setIntegerValueField(.eventSourceUserData, value: KeyboardOutput.syntheticEventTag)
        XCTAssertNotNil(worker.handle(type: .keyDown, event: flags))

        XCTAssertEqual(recorded.events.map(\.phase), [.modifiersChanged, .pressed, .released])
        XCTAssertEqual(recorded.events.first?.keyName, "Left Shift")
        XCTAssertEqual(recorded.events.first?.capsLock, true)
        XCTAssertEqual(recorded.events.last?.stroke.kind, .logitechFunction)
    }

    func testReleaseIsSuppressedWhenCheckerClosesWithAKeyHeld() throws {
        let worker = KeyboardEventWorker()
        worker.setCheckHandler { _ in }
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
        XCTAssertNil(worker.handle(type: .keyDown, event: down))
        worker.setCheckHandler(nil)
        XCTAssertNil(worker.handle(type: .keyUp, event: up))
        XCTAssertNotNil(worker.handle(type: .keyDown, event: down))
    }

    @MainActor
    private func makeStore() -> ShortcutStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ShortcutStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [KeyboardCheckEvent] = []

    var events: [KeyboardCheckEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: KeyboardCheckEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}
