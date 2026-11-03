import Foundation
import Testing

@testable import CadenceUI

/// The login item and the collector agent (docs/SPEC.md sections 8.1, 8.3 and 8.7): what is registered and when,
/// what Settings is told, and that an enabled service is never registered again.
@MainActor @Suite struct LoginItemControllerTests {
    struct Refused: LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }

    /// A service the test controls: it reports a state, counts calls, and moves to another state when registered.
    final class FakeService: ServiceRegistering, @unchecked Sendable {
        private let lock = NSLock()
        private var current: ServiceState
        private var afterRegister: ServiceState
        private var failure: (any Error)?
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0

        init(_ state: ServiceState, afterRegister: ServiceState = .enabled, failing: (any Error)? = nil) {
            current = state
            self.afterRegister = afterRegister
            failure = failing
        }

        func set(_ state: ServiceState) { lock.withLock { current = state } }
        func fail(with error: (any Error)?) { lock.withLock { failure = error } }
        func state() -> ServiceState { lock.withLock { current } }

        func register() throws {
            try lock.withLock {
                registerCalls += 1
                if let failure { throw failure }
                current = afterRegister
            }
        }

        func unregister() throws {
            try lock.withLock {
                unregisterCalls += 1
                if let failure { throw failure }
                current = .notRegistered
            }
        }
    }

    final class FakeMemory: LoginItemMemory, @unchecked Sendable {
        private let lock = NSLock()
        private var saved: [LoginService: Bool]

        init(_ saved: [LoginService: Bool] = [:]) { self.saved = saved }

        func wasEnabled(_ service: LoginService) -> Bool { lock.withLock { saved[service] ?? false } }
        func setEnabled(_ enabled: Bool, for service: LoginService) { lock.withLock { saved[service] = enabled } }
    }

    static func controller(
        app: FakeService, agent: FakeService, memory: FakeMemory = FakeMemory(), registers: Bool = true
    ) -> LoginItemController {
        LoginItemController(app: app, agent: agent, memory: memory, registers: registers)
    }

    // MARK: Registering

    @Test func anEnabledServiceIsNeverRegisteredAgain() {
        let app = FakeService(.enabled)
        let agent = FakeService(.enabled)
        let items = Self.controller(app: app, agent: agent)
        let report = items.ensureRegistered()
        #expect(report.app == .enabled && report.agent == .enabled)
        #expect(app.registerCalls == 0 && agent.registerCalls == 0)
        // Launch after launch: still no calls.
        _ = items.ensureRegistered()
        _ = Self.controller(app: app, agent: agent).ensureRegistered()
        #expect(app.registerCalls == 0 && agent.registerCalls == 0)
        #expect(report.allEnabled)
    }

    @Test func aFirstLaunchRegistersBothOnceAndTheNextLaunchDoesNot() {
        let app = FakeService(.notRegistered)
        let agent = FakeService(.notRegistered)
        let items = Self.controller(app: app, agent: agent)
        let first = items.ensureRegistered()
        #expect(first.app == .enabled && first.agent == .enabled)
        #expect(app.registerCalls == 1 && agent.registerCalls == 1)
        #expect(items.report == first)
        _ = Self.controller(app: app, agent: agent).ensureRegistered()
        #expect(app.registerCalls == 1 && agent.registerCalls == 1)
    }

    @Test func aServiceWaitingForApprovalIsNotRegisteredAgainAndIsReported() {
        let app = FakeService(.requiresApproval)
        let agent = FakeService(.notRegistered, afterRegister: .requiresApproval)
        let report = Self.controller(app: app, agent: agent).ensureRegistered()
        #expect(report.app == .requiresApproval)
        #expect(report.agent == .requiresApproval)  // registered once, and now it is the person's to allow
        #expect(app.registerCalls == 0)
        #expect(agent.registerCalls == 1)
        #expect(!report.allEnabled)
    }

    @Test func aServiceThatIsNotFoundIsReportedAndLeftAlone() {
        let app = FakeService(.enabled)
        let agent = FakeService(.notFound)
        let report = Self.controller(app: app, agent: agent).ensureRegistered()
        #expect(report.agent == .notFound)
        #expect(agent.registerCalls == 0)
        #expect(report.app == .enabled)
    }

    @Test func aRefusedRegistrationIsAFailureWithItsReasonAndTheOtherServiceIsUnaffected() {
        let app = FakeService(.notRegistered, failing: Refused())
        let agent = FakeService(.notRegistered)
        let items = Self.controller(app: app, agent: agent)
        let report = items.ensureRegistered()
        #expect(report.app == .failed("Operation not permitted"))
        #expect(report.agent == .enabled)
        #expect(!report.allEnabled)
        // Looking again does not try again, and does not forget why.
        #expect(items.refresh().app == .failed("Operation not permitted"))
        #expect(app.registerCalls == 1)
        // Once the service is enabled the failure no longer applies.
        app.fail(with: nil)
        app.set(.enabled)
        #expect(items.refresh().app == .enabled)
    }

    @Test func aDevelopmentRunReportsButNeverRegisters() {
        let app = FakeService(.notRegistered)
        let agent = FakeService(.notRegistered)
        let report = Self.controller(app: app, agent: agent, registers: false).ensureRegistered()
        #expect(app.registerCalls == 0 && agent.registerCalls == 0)
        #expect(report.app == .notRegistered && report.agent == .notRegistered)
    }

    @Test func registrationIsForAnInstalledAppAndNeverForADevelopmentRun() {
        let installed = URL(fileURLWithPath: "/Users/someone/Applications/Cadence.app")
        #expect(LoginItemController.registrationAllowed(environment: [:], bundleURL: installed))
        // `make run` sets CADENCE_HOME: a dev run must not register itself, nor an agent that reads the real store.
        #expect(!LoginItemController.registrationAllowed(environment: ["CADENCE_HOME": "/tmp/dev"], bundleURL: installed))
        #expect(!LoginItemController.registrationAllowed(environment: [:], bundleURL: URL(fileURLWithPath: "/tmp/.build/debug/CadenceApp")))
    }

    // MARK: Re-allow after an update

    @Test func aServiceThatNeedsApprovalAfterBeingEnabledIsTheReallowCase() {
        let memory = FakeMemory()
        let app = FakeService(.enabled)
        let agent = FakeService(.enabled)
        _ = Self.controller(app: app, agent: agent, memory: memory).ensureRegistered()
        #expect(memory.wasEnabled(.app) && memory.wasEnabled(.agent))
        // A reinstall under a new ad-hoc signature: macOS asks again.
        app.set(.requiresApproval)
        let report = Self.controller(app: app, agent: agent, memory: memory).ensureRegistered()
        #expect(report.app == .requiresApproval)
        #expect(report.reallow)
        #expect(app.registerCalls == 0)
    }

    @Test func aFirstApprovalIsNotAReallow() {
        let app = FakeService(.notRegistered, afterRegister: .requiresApproval)
        let report = Self.controller(app: app, agent: FakeService(.enabled)).ensureRegistered()
        #expect(report.app == .requiresApproval)
        #expect(!report.reallow)
    }

    @Test func turningItOffInCadenceIsNotAReallowEither() {
        let memory = FakeMemory()
        let app = FakeService(.enabled)
        let items = Self.controller(app: app, agent: FakeService(.enabled), memory: memory)
        _ = items.ensureRegistered()
        #expect(items.setEnabled(false, for: .app) == .notRegistered)
        #expect(!memory.wasEnabled(.app))
        #expect(!items.report.reallow)
    }

    // MARK: Settings

    @Test func settingsCanTurnAServiceOnAndOff() {
        let app = FakeService(.notRegistered)
        let items = Self.controller(app: app, agent: FakeService(.enabled))
        #expect(items.setEnabled(true, for: .app) == .enabled)
        #expect(app.registerCalls == 1)
        #expect(items.setEnabled(true, for: .app) == .enabled)
        #expect(app.registerCalls == 1)  // already on
        #expect(items.setEnabled(false, for: .app) == .notRegistered)
        #expect(app.unregisterCalls == 1)
        #expect(items.setEnabled(false, for: .app) == .notRegistered)
        #expect(app.unregisterCalls == 1)  // already off
        #expect(items.report.app == .notRegistered)
        #expect(items.report.agent == .enabled)
    }

    @Test func aServiceWaitingForApprovalCanBeTurnedOffButNotRegisteredAgain() {
        let app = FakeService(.requiresApproval)
        let items = Self.controller(app: app, agent: FakeService(.enabled))
        #expect(items.setEnabled(true, for: .app) == .requiresApproval)
        #expect(app.registerCalls == 0)
        #expect(items.setEnabled(false, for: .app) == .notRegistered)
        #expect(app.unregisterCalls == 1)
    }

    @Test func aFailureToSwitchIsReportedWithItsReason() {
        let app = FakeService(.enabled, failing: Refused())
        let items = Self.controller(app: app, agent: FakeService(.enabled))
        #expect(items.setEnabled(false, for: .app) == .failed("Operation not permitted"))
        #expect(items.report.app == .failed("Operation not permitted"))
    }

    @Test func refreshOnlyLooksAndTheReportIsPublished() {
        let app = FakeService(.notRegistered)
        let items = Self.controller(app: app, agent: FakeService(.enabled))
        #expect(items.report.app == .notRegistered)  // read when it was made
        let looked = items.refresh()
        #expect(looked.app == .notRegistered)
        #expect(app.registerCalls == 0)
        app.set(.requiresApproval)
        #expect(items.refresh().app == .requiresApproval)
        #expect(items.report == items.refresh())
    }

    @Test func theStatusesReadAsTheyShouldForSettings() {
        let report = LoginItemReport(app: .enabled, agent: .requiresApproval, reallow: false)
        #expect(report[.app] == .enabled)
        #expect(report[.agent] == .requiresApproval)
    }
}
