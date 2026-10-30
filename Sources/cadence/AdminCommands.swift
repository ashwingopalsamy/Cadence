import ArgumentParser
import CadenceCore
import Foundation

struct RebuildCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild", abstract: "Rebuild every projection from the ledger.")

    @OptionGroup var output: OutputOptions

    func run() throws {
        try output.run { context in
            let store = try context.openStore()
            try store.rebuild()
            func count(_ table: String) throws -> Int64 {
                do {
                    return try store.db.first("SELECT COUNT(*) AS n FROM \(table)")?.int("n") ?? 0
                } catch {
                    throw error.cadenceError
                }
            }
            let events = try store.eventCount()
            let days = try count("days")
            let entries = try count("entries")
            let tasks = try count("plan_tasks")
            let spans = try count("presence_spans")
            return Rendered(
                human: "Rebuilt from \(events) events: \(days) days, \(entries) entries, \(tasks) plan tasks, \(spans) presence spans.",
                json: [
                    "events": .int(events), "days": .int(days), "entries": .int(entries), "plan_tasks": .int(tasks),
                    "presence_spans": .int(spans),
                ])
        }
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor",
        abstract: "Check the store, the chain, the config, file modes and the Claude Code setup.")

    @OptionGroup var output: OutputOptions

    struct Check {
        enum Status: String { case ok, warn, fail }
        var name: String
        var status: Status
        var detail: String
    }

    func run() throws {
        let context = CLIContext.current()
        var checks: [Check] = []
        do {
            try context.prepareFolders(repair: false)
        } catch {
            checks.append(Check(name: "folders", status: .fail, detail: error.message))
        }
        checks += Self.permissionChecks(context)
        checks += Self.storeChecks(context)
        checks.append(Self.configCheck(context))
        checks += Self.integrationChecks(context)

        let failed = checks.contains { $0.status == .fail }
        let human = checks.map { "\($0.status.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0))  \($0.name): \($0.detail)" }
            .joined(separator: "\n")
        let json: JSONValue = [
            "ok": .bool(!failed),
            "checks": .array(
                checks.map { ["name": .string($0.name), "status": .string($0.status.rawValue), "detail": .string($0.detail)] }),
        ]
        do {
            try output.emit(Rendered(human: human, json: json))
        } catch {
            throw fail(error)
        }
        if failed { throw ExitCode(CadenceError.validation("").exitCode) }
    }

    static func mode(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let permissions = attributes[.posixPermissions] as? NSNumber
        else { return nil }
        return permissions.intValue & 0o7777
    }

    static func octal(_ mode: Int) -> String {
        let text = String(mode, radix: 8)
        return String(repeating: "0", count: max(0, 4 - text.count)) + text
    }

    static func permissionChecks(_ context: CLIContext) -> [Check] {
        var loose: [String] = []
        var missing: [String] = []
        for folder in context.roots.folders {
            guard let mode = mode(folder) else {
                missing.append(folder.lastPathComponent)
                continue
            }
            if mode != 0o700 { loose.append("\(folder.lastPathComponent) is \(octal(mode)), expected 0700") }
        }
        var checks: [Check] = []
        if !loose.isEmpty {
            checks.append(Check(name: "folders", status: .fail, detail: loose.joined(separator: "; ")))
        } else if !missing.isEmpty {
            checks.append(Check(name: "folders", status: .fail, detail: "missing: " + missing.joined(separator: ", ")))
        } else {
            checks.append(Check(name: "folders", status: .ok, detail: "mode 0700 on \(context.roots.folders.count) folders"))
        }
        if let dbMode = mode(context.roots.database), dbMode & 0o077 != 0 {
            checks.append(
                Check(name: "database file", status: .warn, detail: "mode \(octal(dbMode)); run chmod 600 on cadence.db"))
        }
        let sidecars = ["cadence.db-wal", "cadence.db-shm"].compactMap { name -> String? in
            let url = context.roots.home.appendingPathComponent(name)
            guard let found = mode(url), found != 0o600 else { return nil }
            return "\(name) is \(octal(found))"
        }
        if !sidecars.isEmpty {
            checks.append(
                Check(name: "database sidecars", status: .warn, detail: sidecars.joined(separator: "; ") + ", expected 0600"))
        }
        var readable: [String] = []
        for folder in [context.roots.backups, context.roots.exports] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted() {
                var isFolder: ObjCBool = false
                let url = folder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue,
                    let found = mode(url), found & 0o077 != 0
                else { continue }
                readable.append("\(folder.lastPathComponent)/\(name) is \(octal(found))")
            }
        }
        if !readable.isEmpty {
            checks.append(
                Check(name: "private files", status: .warn, detail: readable.joined(separator: "; ") + "; run chmod 600 on them"))
        }
        return checks
    }

    static func storeChecks(_ context: CLIContext) -> [Check] {
        let store: SQLiteStore
        do {
            store = try context.openStore()
        } catch {
            return [Check(name: "store", status: .fail, detail: error.message)]
        }
        var checks: [Check] = []
        do {
            let version = try store.schemaVersion()
            let supported = Schema.currentVersion
            checks.append(
                Check(
                    name: "store", status: version == supported ? .ok : .fail,
                    detail: version == supported
                        ? "opens, schema version \(version)" : "schema version \(version), this cadence expects \(supported)"))
        } catch {
            checks.append(Check(name: "store", status: .fail, detail: String(describing: error)))
        }
        do {
            let report = try store.verifyChain()
            if report.ok {
                checks.append(
                    Check(
                        name: "ledger", status: .ok,
                        detail: report.events == 0 ? "empty, nothing to verify" : "chain verified over \(report.events) events"))
            } else {
                let shown = report.problems.prefix(3).joined(separator: "; ")
                let more = report.problems.count > 3 ? " (and \(report.problems.count - 3) more)" : ""
                checks.append(Check(name: "ledger", status: .fail, detail: shown + more))
            }
        } catch {
            checks.append(Check(name: "ledger", status: .fail, detail: error.message))
        }
        return checks
    }

    /// Claude Code hooks, MCP registration and skill, the spool backlog, `cleanupPeriodDays` and the collector agent.
    /// These are advice: they warn and never fail, so a Mac without Claude Code still passes.
    static func integrationChecks(_ context: CLIContext) -> [Check] {
        AgentChecks(
            paths: ClaudeCodePaths(userHome: context.userHome), roots: context.roots, clock: context.clock,
            environment: context.environment, runner: SystemProcessRunner(), platform: .current, uid: UInt32(geteuid())
        ).run().map { Check(name: $0.name, status: $0.level == .ok ? .ok : .warn, detail: $0.detail) }
    }

    static func configCheck(_ context: CLIContext) -> Check {
        let file = ConfigStore.check(context.roots.config)
        guard file.exists else {
            return Check(name: "config", status: .warn, detail: "no config file; defaults are in use (cadence config set creates one)")
        }
        do {
            _ = try ConfigStore.load(from: context.roots.config, fallbackZone: TimeZone.current.identifier)
        } catch {
            return Check(name: "config", status: .fail, detail: error.message)
        }
        if let problem = file.problem { return Check(name: "config", status: .warn, detail: problem) }
        return Check(name: "config", status: .ok, detail: "valid, mode \(octal(file.mode))")
    }
}
