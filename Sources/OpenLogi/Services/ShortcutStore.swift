import Combine
import Foundation

@MainActor
final class ShortcutStore: ObservableObject {
    @Published var rules: [ShortcutRule] {
        didSet {
            if !Self.rulesHaveSameLookupTopology(oldValue, rules) {
                rebuildRuleLookup()
            }
            scheduleSave()
        }
    }

    @Published var isEnabled: Bool {
        didSet { scheduleSave() }
    }

    private let fileURL: URL
    private let persistenceWriter: PersistenceWriter
    private var isLoading = true
    private var pendingSave: Task<Void, Never>?
    private var firstEnabledRuleIndexByInput: [KeyStroke: Int] = [:]
    private var enabledRuleCountByInput: [KeyStroke: Int] = [:]
    private var enabledRuleCountByInputAndID: [RuleInputKey: Int] = [:]
    private static let schemaVersion = 2

    private struct SavedState: Codable, Sendable {
        var schemaVersion: Int?
        var rules: [ShortcutRule]
        var isEnabled: Bool
    }

    private struct RuleInputKey: Hashable {
        var input: KeyStroke
        var ruleID: UUID
    }

    init(fileURL: URL? = nil) {
        let resolvedFileURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedFileURL
        self.persistenceWriter = PersistenceWriter(fileURL: resolvedFileURL)
        self.rules = []
        self.isEnabled = true
        let needsSave = load()
        isLoading = false
        if needsSave { flush() }
    }

    func addRule() {
        isEnabled = true
        rules.append(ShortcutRule())
    }

    func addMissionControlRule() {
        isEnabled = true
        let input = KeyStroke.logitechFunction(118)
        if let index = rules.firstIndex(where: {
            $0.input.normalizedForInputMatching == input.normalizedForInputMatching
        }) {
            rules[index].name = "Mission Control"
            rules[index].systemAction = .missionControl
            rules[index].isEnabled = true
            return
        }
        rules.append(ShortcutRule(
            name: "Mission Control",
            input: input,
            systemAction: .missionControl,
            isEnabled: true
        ))
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    func rule(for input: KeyStroke) -> ShortcutRule? {
        guard isEnabled else { return nil }
        guard let index = firstEnabledRuleIndexByInput[input.normalizedForInputMatching],
              rules.indices.contains(index) else { return nil }
        return rules[index]
    }

    func isDuplicate(_ rule: ShortcutRule) -> Bool {
        guard rule.isEnabled else { return false }
        let normalizedInput = rule.input.normalizedForInputMatching
        let enabledCount = enabledRuleCountByInput[normalizedInput, default: 0]
        let sameRuleIDCount = enabledRuleCountByInputAndID[
            RuleInputKey(input: normalizedInput, ruleID: rule.id),
            default: 0
        ]
        return enabledCount > sameRuleIDCount
    }

    /// Persists the latest state before returning. Encoding and file I/O run on
    /// the store's serial persistence queue.
    func flush() {
        guard !isLoading else { return }
        pendingSave?.cancel()
        pendingSave = nil
        persistenceWriter.flush(snapshot())
    }

    private func load() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else {
            return false
        }
        let shouldMigrate = (state.schemaVersion ?? 1) < Self.schemaVersion
        rules = shouldMigrate ? state.rules.map(Self.migrateLegacyFunctionKey) : state.rules
        isEnabled = state.isEnabled
        return shouldMigrate
    }

    private func rebuildRuleLookup() {
        var firstEnabledRuleIndexByInput: [KeyStroke: Int] = [:]
        var enabledRuleCountByInput: [KeyStroke: Int] = [:]
        var enabledRuleCountByInputAndID: [RuleInputKey: Int] = [:]

        for (index, rule) in rules.enumerated() where rule.isEnabled {
            let input = rule.input.normalizedForInputMatching
            if firstEnabledRuleIndexByInput[input] == nil {
                firstEnabledRuleIndexByInput[input] = index
            }
            enabledRuleCountByInput[input, default: 0] += 1
            enabledRuleCountByInputAndID[
                RuleInputKey(input: input, ruleID: rule.id),
                default: 0
            ] += 1
        }

        self.firstEnabledRuleIndexByInput = firstEnabledRuleIndexByInput
        self.enabledRuleCountByInput = enabledRuleCountByInput
        self.enabledRuleCountByInputAndID = enabledRuleCountByInputAndID
    }

    private static func rulesHaveSameLookupTopology(
        _ lhs: [ShortcutRule],
        _ rhs: [ShortcutRule]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.id == right.id
                && left.input == right.input
                && left.isEnabled == right.isEnabled
        }
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            persistenceWriter.write(snapshot())
            pendingSave = nil
        }
    }

    private func snapshot() -> SavedState {
        SavedState(
            schemaVersion: Self.schemaVersion,
            rules: rules,
            isEnabled: isEnabled
        )
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OpenLogi", isDirectory: true)
            .appendingPathComponent("shortcuts.json")
    }

    private static func migrateLegacyFunctionKey(_ rule: ShortcutRule) -> ShortcutRule {
        guard rule.input.kind == .keyboard,
              LogitechFunctionKeyHID.position(forKeyCode: rule.input.keyCode) != nil else {
            return rule
        }
        var migrated = rule
        migrated.input.kind = .logitechFunction
        return migrated
    }

    private final class PersistenceWriter: @unchecked Sendable {
        private let fileURL: URL
        private let queue = DispatchQueue(label: "com.openlogi.shortcut-persistence", qos: .utility)

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func write(_ state: SavedState) {
            queue.async { [self] in
                writeToDisk(state)
            }
        }

        func flush(_ state: SavedState) {
            let completion = DispatchSemaphore(value: 0)
            queue.async { [self] in
                writeToDisk(state)
                completion.signal()
            }
            completion.wait()
        }

        private func writeToDisk(_ state: SavedState) {
            do {
                let data = try JSONEncoder.pretty.encode(state)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            } catch {
                assertionFailure("Could not save shortcuts: \(error)")
            }
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
