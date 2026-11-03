import Foundation
import Observation

/// The two things the app registers with the system (docs/SPEC.md sections 8.1 and 8.3): itself, so it opens at login,
/// and the collector agent, a launchd user agent that runs due collectors.
public enum LoginService: String, Sendable, CaseIterable {
    case app
    case agent
}

/// What the system says about a service, as `SMAppService.Status` says it.
public enum ServiceState: Sendable, Equatable {
    case notRegistered
    case enabled
    /// Registered, and the person has to allow it in System Settings, General, Login Items.
    case requiresApproval
    /// The system cannot find the app or the agent's plist.
    case notFound
}

/// What Settings shows for one service.
public enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    /// The system refused, with its reason. Holds nothing from the log.
    case failed(String)
}

/// SMAppService behind a seam, so the rules below are tested without registering anything.
public protocol ServiceRegistering: Sendable {
    func state() -> ServiceState
    func register() throws
    func unregister() throws
}

/// What an earlier launch saw, kept across launches. It is how a service that needs approval after having been enabled
/// (the "re-allow after an update" case of section 8.3) is told from one that has never been allowed.
public protocol LoginItemMemory: Sendable {
    func wasEnabled(_ service: LoginService) -> Bool
    func setEnabled(_ enabled: Bool, for service: LoginService)
}

/// Both services as Settings and the master failure table read them.
public struct LoginItemReport: Sendable, Equatable {
    public var app: LoginItemStatus
    public var agent: LoginItemStatus
    /// A service was enabled before and now needs approval: macOS asks again after an update under a new ad-hoc
    /// signature (section 8.3). The remedy is the same, to allow it in Login Items; the words can say why.
    public var reallow: Bool

    public init(app: LoginItemStatus, agent: LoginItemStatus, reallow: Bool) {
        self.app = app
        self.agent = agent
        self.reallow = reallow
    }

    public subscript(service: LoginService) -> LoginItemStatus {
        switch service {
        case .app: app
        case .agent: agent
        }
    }

    public var allEnabled: Bool { app == .enabled && agent == .enabled }
}

/// Registers the login item and the collector agent, and says where each stands.
///
/// An enabled service is never registered again, and neither is one waiting for approval or one the system cannot
/// find: only a service that is not registered is. A failure keeps its reason for as long as the service stays in the
/// state it was in when the system refused, and is never retried by looking; the next launch or the Settings switch
/// tries again.
@MainActor @Observable
public final class LoginItemController {
    /// The latest look. Settings reads it.
    public private(set) var report: LoginItemReport

    @ObservationIgnored private let services: [LoginService: any ServiceRegistering]
    @ObservationIgnored private let memory: any LoginItemMemory
    @ObservationIgnored private let registers: Bool
    @ObservationIgnored private var failures: [LoginService: (message: String, state: ServiceState)] = [:]

    /// `registers` is false for a development run, which must not register itself or an agent that reads the real store.
    public init(app: any ServiceRegistering, agent: any ServiceRegistering, memory: any LoginItemMemory, registers: Bool = true) {
        services = [.app: app, .agent: agent]
        self.memory = memory
        self.registers = registers
        report = LoginItemReport(app: .notRegistered, agent: .notRegistered, reallow: false)
        report = look()
    }

    /// An installed app registers; a run with a development store (`make run` sets `CADENCE_HOME`) or outside an app
    /// bundle does not.
    public static func registrationAllowed(environment: [String: String], bundleURL: URL) -> Bool {
        let development = environment["CADENCE_HOME"].map { !$0.isEmpty } ?? false
        return !development && bundleURL.pathExtension == "app"
    }

    /// At launch: registers what is not registered, and only that, then reports.
    @discardableResult
    public func ensureRegistered() -> LoginItemReport {
        if registers {
            for service in LoginService.allCases where services[service]?.state() == .notRegistered {
                attempt(service) { try $0.register() }
            }
        }
        return refresh()
    }

    /// Looks and changes nothing. For Settings, when it opens or the app comes forward after the person was in
    /// System Settings.
    @discardableResult
    public func refresh() -> LoginItemReport {
        report = look()
        return report
    }

    /// The switch in Settings. On registers a service that is not registered; one waiting for approval stays that way,
    /// because only the person can allow it. Off unregisters one that is registered, and is remembered so the next
    /// approval is not mistaken for a re-allow.
    @discardableResult
    public func setEnabled(_ enabled: Bool, for service: LoginService) -> LoginItemStatus {
        guard let registering = services[service] else { return .notFound }
        let state = registering.state()
        if enabled {
            if state == .notRegistered { attempt(service) { try $0.register() } }
        } else {
            if state == .enabled || state == .requiresApproval {
                attempt(service) { try $0.unregister() }
            }
            memory.setEnabled(false, for: service)
        }
        return refresh()[service]
    }

    private func attempt(_ service: LoginService, _ action: (any ServiceRegistering) throws -> Void) {
        guard let registering = services[service] else { return }
        let before = registering.state()
        do {
            try action(registering)
            failures[service] = nil
        } catch {
            failures[service] = ((error as NSError).localizedDescription, before)
        }
    }

    private func look() -> LoginItemReport {
        var reallow = false
        func status(_ service: LoginService) -> LoginItemStatus {
            guard let state = services[service]?.state() else { return .notFound }
            if let failure = failures[service] {
                // Still where it was when the system refused, so the refusal still stands; anything else is news.
                if failure.state == state { return .failed(failure.message) }
                failures[service] = nil
            }
            switch state {
            case .enabled:
                memory.setEnabled(true, for: service)
                return .enabled
            case .requiresApproval:
                if memory.wasEnabled(service) { reallow = true }
                return .requiresApproval
            case .notRegistered:
                return .notRegistered
            case .notFound:
                return .notFound
            }
        }
        return LoginItemReport(app: status(.app), agent: status(.agent), reallow: reallow)
    }
}
