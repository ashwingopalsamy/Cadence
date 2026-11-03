import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

@MainActor
@Suite struct FirstRunTests {
    static let helper = "/Users/you/Applications/Cadence.app/Contents/Helpers/cadence"

    final class Approvals: CollectorApproving {
        var approved: Set<String> = []
        func isApproved(_ plan: CollectorPlan) -> Bool { approved.contains(plan.name) }
        func approve(_ plan: CollectorPlan) throws(CadenceError) { approved.insert(plan.name) }
    }

    /// An empty store: the folder does not exist yet, unless the test writes a config or a map into it.
    static func roots() -> FileRoots {
        FileRoots(home: FileManager.default.temporaryDirectory.appendingPathComponent("cadence-firstrun-\(UUID().uuidString)", isDirectory: true))
    }

    static func defaults() -> UserDefaults {
        let name = "cadence.tests.firstrun.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func withGitHub(_ roots: FileRoots) throws {
        try FileManager.default.createDirectory(at: roots.home, withIntermediateDirectories: true)
        var config = Config.defaults(timezone: "Asia/Kolkata")
        config.collectors = [Config.Collector(name: "github", builtin: "github", env: ["GH_HOST": "git.example.com"], every: "30m")]
        try ConfigStore.save(config, to: roots.config)
    }

    static func model(
        _ roots: FileRoots, defaults: UserDefaults, approvals: Approvals? = nil, copied: @escaping @MainActor (String) -> Void = { _ in },
        finished: @escaping @MainActor () -> Void = {}
    ) -> FirstRunModel {
        FirstRunModel(
            roots: roots, selfExecutable: helper,
            actions: FirstRunActions(approval: approvals, copy: copied, finished: finished), defaults: defaults,
            fallbackZone: "Asia/Kolkata", userHome: URL(fileURLWithPath: "/Users/you"))
    }

    @Test func stepsInOrderWithTheirPoses() {
        #expect(FirstRunStep.allCases.map(\.title) == ["Welcome", "Your data", "GitHub", "Claude Code", "History", "Permissions"])
        #expect(FirstRunStep.allCases.map(\.pose) == [.welcome, .lock, .plug, .laptop, .carry, .raise])
        #expect(FirstRunStep.allCases.filter(\.isSkippable) == [.github, .claudeCode, .history])
    }

    @Test func fromAnEmptyStoreEveryStepIsReachableAndFinishSetsTheFlag() {
        let roots = Self.roots()
        let defaults = Self.defaults()
        var finishedCalls = 0
        let model = Self.model(roots, defaults: defaults) { _ in } finished: { finishedCalls += 1 }
        #expect(model.github == nil)
        #expect(model.importCommand == nil)
        #expect(!PreferenceStore(defaults: defaults).setupFinished)
        var seen: [FirstRunStep] = [model.step]
        for _ in 1..<FirstRunStep.allCases.count {
            model.next()
            seen.append(model.step)
        }
        #expect(seen == FirstRunStep.allCases)
        #expect(model.progress == "Step 6 of 6")
        #expect(!model.finished)
        model.next()  // Finish on the last step
        #expect(model.finished)
        #expect(PreferenceStore(defaults: defaults).setupFinished)
        model.finish()
        #expect(finishedCalls == 1)
        #expect(!FileManager.default.fileExists(atPath: roots.home.path))  // first run wrote nothing to the store
    }

    @Test func onlyOptionalStepsSkip() {
        let model = Self.model(Self.roots(), defaults: Self.defaults())
        model.skip()
        #expect(model.step == .welcome)
        model.next()
        model.skip()
        #expect(model.step == .yourData)
        model.next()
        model.skip()
        model.skip()
        model.skip()
        #expect(model.step == .permissions)
        #expect(model.skipped == [.github, .claudeCode, .history])
        model.skip()
        #expect(model.step == .permissions && !model.finished)
        model.back()
        #expect(model.step == .history)
    }

    @Test func gitHubApprovesTheExactPlan() throws {
        let roots = Self.roots()
        defer { try? FileManager.default.removeItem(at: roots.home) }
        try Self.withGitHub(roots)
        let approvals = Approvals()
        let model = Self.model(roots, defaults: Self.defaults(), approvals: approvals)
        let offer = try #require(model.github)
        #expect(offer.command == "\(Self.helper) collector github --since {since} --until {until} --name github\nGH_HOST=git.example.com")
        #expect(offer.host == "git.example.com")
        #expect(!model.githubApproved)
        model.approveGitHub()
        #expect(model.githubApproved)
        #expect(approvals.approved == ["github"])
        let expected = try CollectorRunner.plan(for: Config.Collector(name: "github", builtin: "github", env: ["GH_HOST": "git.example.com"], every: "30m"), selfExecutable: Self.helper)
        #expect(offer.plan.digest == expected.digest)
    }

    @Test func gitHubWithoutCoreApprovalPointsToSettings() throws {
        let roots = Self.roots()
        defer { try? FileManager.default.removeItem(at: roots.home) }
        try Self.withGitHub(roots)
        let model = Self.model(roots, defaults: Self.defaults())
        model.approveGitHub()
        #expect(!model.githubApproved)
        #expect(model.githubProblem == "Cadence could not record the approval here. Approve it in Settings, Sources.")
    }

    @Test func claudeCodeAndHistoryCopyTheirCommands() throws {
        let roots = Self.roots()
        defer { try? FileManager.default.removeItem(at: roots.home) }
        try FileManager.default.createDirectory(at: roots.maps, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: roots.maps.appendingPathComponent("october-app.json").path, contents: Data("{}".utf8))
        var copied: [String] = []
        let model = Self.model(roots, defaults: Self.defaults()) { copied.append($0) }
        #expect(model.importCommand == "cadence import genai ~/Downloads/october-usage.csv --map maps/october-app.json --dry-run")
        model.copyCommand(for: .claudeCode)
        model.copyCommand(for: .history)
        #expect(copied == ["cadence setup claude-code --apply", model.importCommand!])
        #expect(model.copied == [.claudeCode, .history])
    }

    @Test func permissionsAskThroughTheirClosures() async {
        var asked = 0
        let model = FirstRunModel(
            roots: Self.roots(), selfExecutable: Self.helper,
            actions: FirstRunActions(
                loginItem: LoginItemControl(status: { false }, set: { $0 }),
                notifications: NotificationControl(status: { .notAsked }, request: { asked += 1; return .allowed })),
            defaults: Self.defaults(), fallbackZone: "Asia/Kolkata")
        #expect(model.openAtLogin == false)
        await model.setOpenAtLogin(true)
        await model.setReminders(true)
        #expect(model.openAtLogin == true)
        #expect(model.notifications == .allowed)
        #expect(asked == 1)
    }
}
