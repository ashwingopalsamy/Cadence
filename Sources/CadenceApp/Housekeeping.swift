// Housekeeping's one macOS-only piece: where the collector agent's registration is read from. The jobs themselves, their
// schedule and their health are in CadenceUI, where they are tested (docs/SPEC.md sections 8.1 and 8.7, S2).
import CadenceUI
import Foundation
import ServiceManagement

/// The agent's registration as `SMAppService` reports it, for the agent plist this bundle ships. A login-item layer
/// that registers the agent (T3.13) can conform to `AgentStatusReading` itself and replace this.
struct SMAppServiceAgentStatus: AgentStatusReading {
    let plistName: String

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        // The same name `--unregister` and the bundle script use.
        plistName = "\(bundleIdentifier ?? "in.ashwingopalsamy.cadence").agent.plist"
    }

    func registration() -> AgentRegistration {
        switch SMAppService.agent(plistName: plistName).status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }
}
