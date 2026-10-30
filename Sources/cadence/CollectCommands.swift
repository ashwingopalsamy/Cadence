import ArgumentParser
import CadenceCore
import Foundation

struct CollectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collect", abstract: "Run collectors, approve their commands and see how they are doing.",
        subcommands: [CollectRunCommand.self, CollectApproveCommand.self, CollectStatusCommand.self])
}

/// The absolute path of the running binary, with symlinks resolved so `~/.local/bin/cadence` and the copy inside the
/// app bundle give the same approval digest.
func currentExecutablePath() -> String {
    if let url = Bundle.main.executableURL { return url.resolvingSymlinksInPath().path }
    let first = CommandLine.arguments.first ?? "cadence"
    if first.hasPrefix("/") { return URL(fileURLWithPath: first).resolvingSymlinksInPath().path }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(first)
        .resolvingSymlinksInPath().path
}

extension CLIContext {
    /// A scheduler over the real store, running commands for real.
    func openScheduler() throws(CadenceError) -> (scheduler: CollectScheduler, runner: CollectorRunner, journal: Journal) {
        let journal = try openJournal()
        let config = journal.config
        guard let zone = TimeZone(identifier: config.profile.timezone) else {
            throw CadenceError.validation("profile.timezone: '\(config.profile.timezone)' is not a time zone")
        }
        let transform = MapTransform(
            roots: roots, zone: zone, boundary: config.dayBoundary, clock: clock,
            ids: ULIDGenerator(clock: clock, random: SystemRandomSource()))
        let runner = CollectorRunner(
            roots: roots, journal: journal, runner: SystemProcessRunner(), selfExecutable: currentExecutablePath(),
            environment: environment, transform: transform)
        return (CollectScheduler(runner: runner, journal: journal, roots: roots, clock: clock), runner, journal)
    }
}

// MARK: - Wording

enum CollectText {
    /// One plain line for one run.
    static func line(_ step: CollectStep) -> String {
        let name = step.collector
        switch step.result {
        case .refused(.notApproved):
            return "\(name): not run, \(CollectorRefusal.notApproved.message). Run cadence collect approve --name \(name)"
        case .refused(let why):
            return "\(name): not run, \(why.message)"
        case .ran(let report):
            let window = "\(step.window.since) to \(step.window.until)"
            if report.status == "ok" {
                var parts = ["\(report.count("created")) new", "\(report.count("updated")) updated", "\(report.count("unchanged")) unchanged"]
                if report.count("skipped") > 0 { parts.append("\(report.count("skipped")) skipped") }
                return "\(name): ran for \(window), " + parts.joined(separator: ", ")
            }
            let why = report.problems.first.map { ", \($0)" } ?? ""
            return "\(name): failed for \(window)\(why)"
        }
    }

    static func json(_ step: CollectStep) -> JSONValue {
        var object: [String: JSONValue] = [
            "collector": .string(step.collector),
            "window": ["since": .string(step.window.since), "until": .string(step.window.until)],
        ]
        switch step.result {
        case .refused(let why):
            object["outcome"] = "refused"
            object["reason"] = .string(why.message)
        case .ran(let report):
            object["outcome"] = .string(report.status == "ok" ? "ok" : "error")
            var counts: [String: JSONValue] = [:]
            for (key, value) in report.counts { counts[key] = .int(value) }
            object["counts"] = .object(counts)
            object["problems"] = .array(report.problems.map { .string($0) })
        }
        return .object(object)
    }

    static func line(_ outcome: CollectJobOutcome) -> [String] {
        guard let job = outcome.job else { return ["job \(outcome.file): not a valid job, \(outcome.removed ? "removed" : "left in place")"] }
        let lines = outcome.steps.map(line)
        return outcome.removed ? lines : lines + ["job \(outcome.file): kept, another run is in progress"]
    }
}

// MARK: - run

struct CollectRunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run collectors now.",
        discussion: """
            --due handles any requests the app left in jobs/ and then runs every collector whose schedule says it is due, one at a \
            time. --name runs one collector for the usual window (the last good day minus 3 days, through today). With \
            --backfill-from it reads from that day to today; with --since and --until it reads exactly that window. A window \
            longer than 7 days runs in 7-day chunks, oldest first, and stops at the first failure. Either form first drains the \
            hook spool, and a drain that fails is reported on stderr without stopping the run. A refused or failed collector \
            does not change the exit status; only a failing store does.
            """)

    @Flag(name: .long, help: "Process jobs, then run every collector that is due.") var due = false
    @Option(name: .long, help: "Run only this collector.") var name: String?
    @Option(name: .customLong("backfill-from"), help: "First day to read, YYYY-MM-DD. Needs --name.") var backfillFrom: String?
    @Option(name: .long, help: "First day of an exact window, YYYY-MM-DD. Needs --name and --until.") var since: String?
    @Option(name: .long, help: "Last day of an exact window, YYYY-MM-DD, today at most. Needs --name and --since.") var until: String?
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if !due && name == nil { throw ValidationError("pass --due or --name NAME") }
        if due && (name != nil || backfillFrom != nil || since != nil || until != nil) {
            throw ValidationError("--due cannot be combined with --name, --backfill-from, --since or --until")
        }
        if backfillFrom != nil && name == nil { throw ValidationError("--backfill-from needs --name") }
        if (since == nil) != (until == nil) { throw ValidationError("--since and --until go together") }
        if since != nil && name == nil { throw ValidationError("--since and --until need --name") }
        if since != nil && backfillFrom != nil { throw ValidationError("--since and --until cannot be combined with --backfill-from") }
    }

    /// Hook lines wait in `spool/` until some `cadence` run drains them (docs/SPEC.md section 9.3). Collecting is one
    /// of those runs. Best effort: a drain that fails is logged on stderr and the collectors run anyway.
    static func drainSpool(_ context: CLIContext, _ journal: Journal) -> JSONValue {
        do {
            let report = try SpoolDrain(roots: context.roots, store: journal.store, config: journal.config, clock: context.clock).drain()
            return report.json
        } catch {
            writeLine("cadence: spool drain failed: \(error.message)", to: FileHandle.standardError)
            return ["error": .string(error.message)]
        }
    }

    func run() throws {
        try output.run { context in
            let from = try Args.date(backfillFrom, option: "backfill-from")
            let sinceDay = try Args.date(since, option: "since")
            let untilDay = try Args.date(until, option: "until")
            let (scheduler, _, journal) = try context.openScheduler()
            if let from { try scheduler.validateBackfillStart(from) }
            if let sinceDay, let untilDay { try scheduler.validateWindow(since: sinceDay, until: untilDay) }
            let spool = Self.drainSpool(context, journal)
            var steps: [CollectStep] = []
            var jobLines: [String] = []
            var jobs: [JSONValue] = []
            if due {
                for outcome in try scheduler.processJobs() {
                    steps += outcome.steps
                    jobLines += CollectText.line(outcome)
                    jobs.append([
                        "file": .string(outcome.file), "valid": .bool(outcome.job != nil), "removed": .bool(outcome.removed),
                        "runs": .array(outcome.steps.map(CollectText.json)),
                    ])
                }
                let ran = try scheduler.runDue()
                steps += ran
                jobLines += ran.map(CollectText.line)
                if ran.isEmpty && jobLines.isEmpty { jobLines = ["nothing is due"] }
            } else if let name {
                let list: [CollectStep]
                if let sinceDay, let untilDay {
                    list = try scheduler.runWindow(name: name, since: sinceDay, until: untilDay)
                } else if from != nil {
                    list = try scheduler.backfill(name: name, from: from)
                } else {
                    list = try scheduler.runIncremental(name: name)
                }
                steps = list
                jobLines = list.map(CollectText.line)
            }
            return Rendered(
                human: jobLines.joined(separator: "\n"),
                json: ["runs": .array(steps.map(CollectText.json)), "jobs": .array(jobs), "spool": spool])
        }
    }
}

// MARK: - approve

struct CollectApproveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve", abstract: "Approve exactly what a collector runs.",
        discussion: """
            Prints the command and environment as they will run, then asks. The approval covers that digest only: change the \
            command, its arguments or its environment and the collector is refused until you approve again.
            """)

    @Option(name: .long, help: "Collector name from config.json.") var name: String
    @Flag(name: .long, help: "Approve without asking. Required when there is no terminal.") var yes = false

    func run() throws {
        do {
            let context = CLIContext.current()
            let config = try context.loadConfig().config
            guard let collector = config.collectors.first(where: { $0.name == name }) else {
                throw CadenceError.notFound("there is no collector named \(name) in config.json")
            }
            let plan = try CollectorRunner.plan(for: collector, selfExecutable: currentExecutablePath())
            writeLine(plan.approvalText, to: FileHandle.standardOutput)
            if !yes {
                guard isatty(STDIN_FILENO) != 0 else {
                    throw CadenceError.validation("cannot ask without a terminal; check the command above and pass --yes to approve it")
                }
                FileHandle.standardOutput.write(Data("Approve this command? [y/N] ".utf8))
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                guard answer == "y" || answer == "yes" else {
                    writeLine("Not approved.", to: FileHandle.standardOutput)
                    return
                }
            }
            let journal = try context.openJournal()
            let runner = CollectorRunner(
                roots: context.roots, journal: journal, runner: SystemProcessRunner(), selfExecutable: currentExecutablePath(),
                environment: context.environment)
            try runner.approve(plan)
            writeLine("Approved \(name).", to: FileHandle.standardOutput)
        } catch let error as CadenceError {
            throw fail(error)
        }
    }
}

// MARK: - status

struct CollectStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show each collector: enabled, approved, last run and health.",
        discussion: "A collector shows as failing after three failed runs in a row.")

    @OptionGroup var output: OutputOptions

    func run() throws {
        try output.run { context in
            let (scheduler, runner, journal) = try context.openScheduler()
            let zone = TimeZone(identifier: journal.config.profile.timezone) ?? .current
            var lines: [String] = []
            var items: [JSONValue] = []
            for collector in journal.config.collectors {
                let approved = (try? CollectorRunner.plan(for: collector, selfExecutable: currentExecutablePath())).map(runner.isApproved) ?? false
                let history = try scheduler.history(name: collector.name)
                let health = try runner.health(name: collector.name)
                let last = history.lastRun.map { "\(Timestamp.local($0, in: zone)) (\(history.lastStatus ?? "unknown"))" } ?? "never"
                let state = health.isFailing ? "failing, \(health.failuresInARow) failed runs in a row" : health.failuresInARow > 0 ? "\(health.failuresInARow) failed, not yet an error" : "ok"
                lines.append(
                    "\(collector.name): \(collector.enabled ? "enabled" : "disabled"), \(approved ? "approved" : "not approved"), last run \(last), health \(state)")
                var item: [String: JSONValue] = [
                    "name": .string(collector.name), "enabled": .bool(collector.enabled), "approved": .bool(approved),
                    "due": .bool(scheduler.isDue(collector, history: history)),
                    "failures_in_a_row": .int(Int64(health.failuresInARow)), "failing": .bool(health.isFailing),
                    "last_run": history.lastRun.map { .string(Timestamp.utc($0)) } ?? .null,
                    "last_status": history.lastStatus.map { .string($0) } ?? .null,
                ]
                if let error = health.lastError { item["last_error"] = .string(error) }
                items.append(.object(item))
            }
            if lines.isEmpty { lines = ["no collectors in config.json"] }
            return Rendered(human: lines.joined(separator: "\n"), json: ["collectors": .array(items)])
        }
    }
}
