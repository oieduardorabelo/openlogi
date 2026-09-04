import Combine
import ServiceManagement

protocol LaunchAtLoginServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginServicing {}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    enum State: Equatable {
        case disabled
        case enabled
        case requiresApproval
        case unavailable(String)

        var isRegistered: Bool {
            switch self {
            case .enabled, .requiresApproval: true
            case .disabled, .unavailable: false
            }
        }

        var canToggle: Bool {
            if case .unavailable = self { return false }
            return true
        }

        var notice: String? {
            switch self {
            case .requiresApproval:
                "Allow OpenLogi under System Settings → General → Login Items to start it automatically."
            case .unavailable(let message):
                message
            case .disabled, .enabled:
                nil
            }
        }
    }

    @Published private(set) var state: State
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool { state.isRegistered }
    var canToggle: Bool { state.canToggle }
    var notice: String? { errorMessage ?? state.notice }
    var requiresApproval: Bool { state == .requiresApproval }

    private let service: any LaunchAtLoginServicing

    init(service: any LaunchAtLoginServicing = SMAppService.mainApp) {
        self.service = service
        self.state = Self.state(for: service.status)
        self.errorMessage = nil
    }

    func refresh() {
        errorMessage = nil
        state = Self.state(for: service.status)
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        guard enabled != state.isRegistered else {
            refresh()
            return
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            state = Self.state(for: service.status)
        } catch {
            state = Self.state(for: service.status)
            if state.isRegistered != enabled {
                let action = enabled ? "enable" : "disable"
                errorMessage = "Could not \(action) Start at Login: \(error.localizedDescription)"
            }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func state(for status: SMAppService.Status) -> State {
        if status == .notRegistered || status == .notFound { return .disabled }
        if status == .enabled { return .enabled }
        if status == .requiresApproval { return .requiresApproval }
        return .unavailable("Start at Login is unavailable on this system.")
    }
}
