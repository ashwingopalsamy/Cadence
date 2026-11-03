// The login item and the collector agent (docs/SPEC.md sections 8.1 and 8.3): SMAppService behind the seam that
// `LoginItemController` in CadenceUI is tested through. Both services are registered by the app itself, from
// `~/Applications`, which S2 proved works for the ad-hoc signed app (docs/SPIKES.md), so no LaunchAgent fallback exists.
import CadenceUI
import Foundation
import ServiceManagement

/// One `SMAppService`. The system's object is not `Sendable`, and every call here is a short request to the system.
struct SystemService: ServiceRegistering, @unchecked Sendable {
    let service: SMAppService

    func state() -> ServiceState {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

/// What a past launch saw, in the app's own defaults (inside the sandbox container).
struct DefaultsLoginItemMemory: LoginItemMemory, @unchecked Sendable {
    let defaults: UserDefaults

    private func key(_ service: LoginService) -> String { "loginItem.\(service.rawValue).wasEnabled" }
    func wasEnabled(_ service: LoginService) -> Bool { defaults.bool(forKey: key(service)) }
    func setEnabled(_ enabled: Bool, for service: LoginService) { defaults.set(enabled, forKey: key(service)) }
}

extension LoginItemController {
    /// The controller for this app: the main app and the agent whose plist is `<bundle id>.agent.plist` in the bundle
    /// (`scripts/bundle.sh`). It registers only an installed app that is not on a development store.
    static func forThisApp() -> LoginItemController {
        let id = Bundle.main.bundleIdentifier ?? ""
        return LoginItemController(
            app: SystemService(service: .mainApp), agent: SystemService(service: .agent(plistName: "\(id).agent.plist")),
            memory: DefaultsLoginItemMemory(defaults: .standard),
            registers: registrationAllowed(environment: ProcessInfo.processInfo.environment, bundleURL: Bundle.main.bundleURL))
    }

    /// Opens System Settings at Login Items, where a service that needs approval is allowed.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
