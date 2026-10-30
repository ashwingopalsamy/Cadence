import CadenceCore
import Foundation
import Testing

/// Each test runs the real binary against its own temp home.
@Suite struct CommandTests {
    let cli = CLIHome()

    func id(_ value: JSONValue, _ key: String) throws -> String {
        try #require(value[key]?["id"]?.stringValue)
    }

    // MARK: log, today

    @Test func logThenTodayShowsIt() throws {
        defer { cli.remove() }
        let logged = try cli.run(["log", "Merged ACME-482913 retry budget at 10:30 ~45m #quality"])
        #expect(logged.status == 0)
        #expect(logged.stdout.contains("Logged for"))
        #expect(logged.stdout.contains("ACME-482913"))
        #expect(logged.stderr.isEmpty)

        let today = try cli.json(["today"])
        let entries = try #require(today["entries"]?.arrayValue)
        #expect(entries.count == 1)
        #expect(entries[0]["title"]?.stringValue == "Merged ACME-482913 retry budget")
        #expect(entries[0]["origin"]?.stringValue == "self")
        #expect(entries[0]["ticket"]?["class"]?.stringValue == "assigned")
        #expect(entries[0]["duration_s"]?.intValue == 2700)

        let human = try cli.run(["today"])
        #expect(human.status == 0)
        #expect(human.stdout.contains("Merged ACME-482913 retry budget"))
        #expect(human.stdout.contains("First activity -, last activity -"))
        #expect(!human.stdout.contains("\u{2013}") && !human.stdout.contains("\u{2014}"))
    }

    @Test func logFlagsOverrideTheParse() throws {
        defer { cli.remove() }
        let today = try cli.today()
        let yesterday = today.adding(days: -1)
        let result = try cli.json([
            "log", "Helped with the release", "--kind", "mentoring", "--at", "09:15", "--date", yesterday.description,
            "--ticket", "ACME-000000", "--link", "https://git.example.com/acme/core/pull/7", "--qty", "2",
            "--duration", "30", "--note", "pairing session",
        ])
        let entry = try #require(result["entry"])
        #expect(entry["kind"]?.stringValue == "mentoring")
        #expect(entry["day"]?.stringValue == yesterday.description)
        #expect(entry["backfilled"]?.boolValue == true)
        #expect(entry["status"]?.stringValue == "accepted")
        #expect(entry["occurred_at"]?.stringValue?.contains("T09:15:00") == true)
        #expect(entry["ticket"]?["class"]?.stringValue == "self")
        #expect(entry["links"]?.arrayValue?.first?["kind"]?.stringValue == "pr")
        #expect(entry["quantity"]?.intValue == 2)
        #expect(entry["duration_s"]?.intValue == 1800)
        #expect(entry["attrs"]?["note"]?.stringValue == "pairing session")
    }

    // MARK: plan

    @Test func planAddListDone() throws {
        defer { cli.remove() }
        let added = try cli.json(["plan", "add", "Write the RFC for ACME-482913", "--estimate", "60"])
        let taskID = try id(added, "task")
        #expect(added["task"]?["position"]?.intValue == 1)
        #expect(added["task"]?["estimate_min"]?.intValue == 60)
        #expect(added["task"]?["ticket"]?["key"]?.stringValue == "ACME-482913")
        let second = try cli.json(["plan", "add", "Review the retry budget"])
        let secondID = try id(second, "task")
        #expect(second["task"]?["position"]?.intValue == 2)

        let list = try cli.json(["plan", "list"])
        #expect(list["tasks"]?.arrayValue?.count == 2)
        let human = try cli.run(["plan", "list"])
        #expect(human.stdout.contains("Plan: 0 of 2 done"))

        let done = try cli.json(["plan", "done", taskID, "--note", "shipped"])
        #expect(done["task"]?["status"]?.stringValue == "done")
        #expect(done["task"]?["reason_note"]?.stringValue == "shipped")
        #expect(done["task"]?["resolved_at"]?.stringValue != nil)

        let slip = try cli.run(["plan", "slip", secondID, "--json"])
        #expect(slip.status == 2)
        #expect(slip.stderr.hasPrefix("cadence: "))
        let slipped = try cli.json(["plan", "slip", secondID, "--reason", "reprioritised"])
        #expect(slipped["task"]?["status"]?.stringValue == "slipped")
        let dropped = try cli.json(["plan", "drop", secondID, "--reason", "not needed"])
        #expect(dropped["task"]?["status"]?.stringValue == "dropped")

        #expect(try cli.run(["plan", "list"]).stdout.contains("Plan: 1 of 2 done"))
    }

    @Test func planDoneLinksAnEntry() throws {
        defer { cli.remove() }
        let entryID = try id(try cli.json(["log", "Wrote the RFC"]), "entry")
        let taskID = try id(try cli.json(["plan", "add", "Write the RFC"]), "task")
        let done = try cli.json(["plan", "done", taskID, "--link", entryID])
        #expect(done["task"]?["linked_entries"]?.arrayValue?.first?.stringValue == entryID)
        #expect(try cli.run(["plan", "done", taskID, "--link", "NOPE"]).status == 4)
    }

    // MARK: day

    @Test func dayLeaveAndHoliday() throws {
        defer { cli.remove() }
        let leave = try cli.json(["day", "leave", "2026-10-12", "--unplanned", "--label", "unwell"])
        #expect(leave["day"]?["kind"]?.stringValue == "leave_unplanned")
        #expect(leave["day"]?["label"]?.stringValue == "unwell")
        let planned = try cli.json(["day", "leave", "2026-10-13"])
        #expect(planned["day"]?["kind"]?.stringValue == "leave_planned")
        let holiday = try cli.json(["day", "holiday", "2026-10-14", "--label", "Founders day"])
        #expect(holiday["day"]?["kind"]?.stringValue == "holiday")

        let shown = try cli.json(["day", "show", "--date", "2026-10-12"])
        #expect(shown["day"]?["kind"]?.stringValue == "leave_unplanned")
        let human = try cli.run(["day", "show", "--date", "2026-10-14"])
        #expect(human.stdout.contains("holiday: Founders day"))
    }

    @Test func dayStartEndShowFirstAndLastActivity() throws {
        defer { cli.remove() }
        let started = try cli.json(["day", "start", "--at", "09:05"])
        #expect(started["day"]?["first_activity"]?.stringValue?.contains("T09:05:00") == true)
        try cli.run(["day", "end", "--at", "17:40"])
        let today = try cli.json(["today"])
        #expect(today["day"]?["last_activity"]?.stringValue?.contains("T17:40:00") == true)
        let human = try cli.run(["today"])
        #expect(human.stdout.contains("First activity 09:05, last activity 17:40"))
    }

    @Test func dayShowForAnEmptyDayIsNotZeros() throws {
        defer { cli.remove() }
        // 2026-10-17 is a Saturday.
        let shown = try cli.json(["day", "show", "--date", "2026-10-17"])
        #expect(shown["day"]?["kind"]?.stringValue == "weekend")
        #expect(shown["day"]?["first_activity"] == .null)
        #expect(shown["entries"]?.arrayValue?.isEmpty == true)
        let human = try cli.run(["day", "show", "--date", "2026-10-17"])
        #expect(human.stdout.contains("First activity -, last activity -"))
        #expect(human.stdout.contains("No plan"))
        #expect(human.stdout.contains("No entries"))
    }

    // MARK: inbox

    @Test func inboxAcceptAndDismissProposals() throws {
        defer { cli.remove() }
        let journal = try cli.journal()
        let yesterday = journal.today().adding(days: -1)
        var request = LogRequest(text: "Reviewed the retry budget doc")
        request.date = yesterday
        let first = try journal.log(request, actor: .mcp, origin: .agent)
        request.text = "Fixed the flaky test"
        let second = try journal.log(request, actor: .mcp, origin: .agent)
        #expect(first.status == .proposed)

        let list = try cli.json(["inbox", "list"])
        #expect(list["entries"]?.arrayValue?.count == 2)
        #expect(try cli.run(["inbox", "list"]).stdout.contains("Proposed entries: 2"))

        let accepted = try cli.json(["inbox", "accept", first.id])
        #expect(accepted["entry"]?["status"]?.stringValue == "accepted")
        #expect(accepted["entry"]?["origin"]?.stringValue == "agent")
        let dismissed = try cli.json(["inbox", "dismiss", second.id])
        #expect(dismissed["entry"]?["status"]?.stringValue == "dismissed")

        #expect(try cli.json(["inbox", "list"])["entries"]?.arrayValue?.isEmpty == true)
        #expect(try cli.run(["inbox", "list"]).stdout.contains("The inbox is empty."))
        #expect(try cli.run(["inbox", "dismiss", "NOPE"]).status == 4)
        // An accepted entry cannot be accepted again.
        #expect(try cli.run(["inbox", "accept", first.id]).status == 2)
    }

    // MARK: query

    @Test func queryTableJsonAndNdjson() throws {
        defer { cli.remove() }
        try cli.run(["log", "Fixed the flaky test"])
        try cli.run(["log", "Reviewed the retry budget"])
        try cli.run(["log", "Thinking about the roadmap"])

        let table = try cli.run(["query"])
        #expect(table.status == 0)
        #expect(table.stdout.contains("KIND"))
        #expect(table.stdout.contains("Fixed the flaky test"))

        let nd = try cli.run(["query", "--ndjson"])
        #expect(nd.status == 0)
        let lines = nd.stdout.split(separator: "\n")
        #expect(lines.count == 3)
        for line in lines { _ = try JSONParser.parse(String(line)) }

        let reviews = try cli.json(["query", "--kind", "review.given"])
        #expect(reviews["entries"]?.arrayValue?.count == 1)
        #expect(reviews["next"] == .null)
        let families = try cli.json(["query", "--family", "delivery", "--origin", "self", "--status", "accepted"])
        #expect(families["entries"]?.arrayValue?.count == 1)

        let today = try cli.today()
        let none = try cli.json(["query", "--from", today.adding(days: -9).description, "--to", today.adding(days: -2).description])
        #expect(none["entries"]?.arrayValue?.isEmpty == true)
    }

    @Test func queryPagesWithACursor() throws {
        defer { cli.remove() }
        for n in 1...3 { try cli.run(["log", "Fixed thing \(n)"]) }
        let one = try cli.json(["query", "--limit", "2"])
        #expect(one["entries"]?.arrayValue?.count == 2)
        let cursor = try #require(one["next"]?.stringValue)
        let two = try cli.json(["query", "--limit", "2", "--cursor", cursor])
        #expect(two["entries"]?.arrayValue?.count == 1)
        #expect(two["next"] == .null)
        #expect(try cli.run(["query", "--cursor", "bogus"]).status == 2)
        #expect(try cli.run(["query", "--kind", "nonsense"]).status == 2)
    }

    // MARK: rebuild, doctor

    @Test func rebuildKeepsTodayIdentical() throws {
        defer { cli.remove() }
        try cli.run(["log", "Fixed the flaky test"])
        try cli.run(["plan", "add", "Write the RFC", "--estimate", "30"])
        try cli.run(["day", "start", "--at", "09:00"])
        try cli.run(["day", "leave", "2026-10-12"])
        let before = try cli.run(["today", "--json"])
        let rebuilt = try cli.json(["rebuild"])
        #expect(rebuilt["events"]?.intValue == 5)
        #expect(rebuilt["entries"]?.intValue == 1)
        #expect(rebuilt["plan_tasks"]?.intValue == 1)
        #expect(try cli.run(["today", "--json"]).stdout == before.stdout)
        #expect(try cli.run(["rebuild"]).stdout.contains("Rebuilt from 5 events"))
    }

    @Test func doctorOnAFreshHomeIsHealthy() throws {
        defer { cli.remove() }
        let result = try cli.run(["doctor"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("ok    store: opens, schema version 1"))
        #expect(result.stdout.contains("ok    folders"))
        #expect(result.stdout.contains("warn  config: no config file"))
        let json = try cli.json(["doctor"])
        #expect(json["ok"]?.boolValue == true)
        #expect(json["checks"]?.arrayValue?.contains { $0["name"]?.stringValue == "ledger" } == true)
    }

    @Test func doctorVerifiesTheChainAfterWrites() throws {
        defer { cli.remove() }
        try cli.run(["log", "Fixed the flaky test"])
        let result = try cli.run(["doctor"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("chain verified over 2 events"))
    }

    @Test func doctorFailsOnATamperedLedger() throws {
        defer { cli.remove() }
        try cli.run(["log", "Fixed the flaky test"])
        let db = try SQLiteDatabase(path: cli.database)
        try db.execute("DROP TRIGGER events_no_update")
        try db.execute("UPDATE events SET data = replace(data, 'flaky', 'steady') WHERE type = 'entry.created'")
        let result = try cli.run(["doctor"])
        #expect(result.status == 2)
        #expect(result.stdout.contains("fail  ledger"))
    }

    @Test func doctorFailsOnLooseFolders() throws {
        defer { cli.remove() }
        try cli.run(["rebuild"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.home.path)
        let result = try cli.run(["doctor"])
        #expect(result.status == 2)
        #expect(result.stdout.contains("fail  folders"))
    }

    // MARK: config

    @Test func doctorAcceptsASavedConfigAndRejectsABrokenOne() throws {
        defer { cli.remove() }
        try cli.run(["config", "set", "sounds", "full"])
        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 0)
        #expect(doctor.stdout.contains("ok    config: valid, mode 0600"))
        try Data("{ not json".utf8).write(to: cli.configFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cli.configFile.path)
        #expect(try cli.run(["today"]).status == 2)
        #expect(try cli.run(["doctor"]).status == 2)
    }

    @Test func configTimezoneIsUsed() throws {
        defer { cli.remove() }
        try cli.run(["config", "set", "profile.timezone", "Asia/Kolkata"])
        let entry = try cli.json(["log", "Fixed the flaky test", "--at", "10:30"])["entry"]
        #expect(entry?["occurred_at"]?.stringValue?.hasSuffix("T10:30:00+05:30") == true)
    }

    // MARK: exit codes

    @Test func commandUsageErrorsExitOne() throws {
        defer { cli.remove() }
        #expect(try cli.run(["log"]).status == 1)
        #expect(try cli.run(["log", "x", "--bogus"]).status == 1)
        #expect(try cli.run(["plan", "add"]).status == 1)
    }

    @Test func missingTasksAndEntriesExitFour() throws {
        defer { cli.remove() }
        #expect(try cli.run(["plan", "done", "NOPE"]).status == 4)
        #expect(try cli.run(["inbox", "accept", "NOPE"]).status == 4)
        let missing = try cli.run(["plan", "drop", "NOPE", "--json"])
        #expect(missing.status == 4)
        #expect(missing.stdout.isEmpty)
    }

    @Test func todayJsonIsOneCanonicalLine() throws {
        defer { cli.remove() }
        let result = try cli.run(["today", "--json"])
        #expect(result.status == 0)
        #expect(result.stdout.hasSuffix("}\n"))
        #expect(result.stdout.dropLast().firstIndex(of: "\n") == nil)
        #expect(try CanonicalJSON.string(try result.json()) + "\n" == result.stdout)
    }

    @Test func validationErrorsExitTwo() throws {
        defer { cli.remove() }
        let badDate = try cli.run(["day", "show", "--date", "2026-02-30"])
        #expect(badDate.status == 2)
        #expect(badDate.stderr.hasPrefix("cadence: "))
        #expect(badDate.stdout.isEmpty)
        #expect(try cli.run(["day", "leave", "next tuesday"]).status == 2)
        #expect(try cli.run(["log", "Fixed it", "--kind", "bogus"]).status == 2)
        #expect(try cli.run(["log", "Fixed it", "--at", "25:00"]).status == 2)
        #expect(try cli.run(["log", "   "]).status == 2)
        #expect(try cli.run(["log", "Fixed it", "--qty", "0"]).status == 2)
    }

    @Test func busyStoreExitsThreeAndReadsStillWork() throws {
        defer { cli.remove() }
        try cli.run(["today"])  // writes the genesis event, so reads need no write lock afterwards
        let blocker = try SQLiteDatabase(path: cli.database)
        try blocker.execute("BEGIN IMMEDIATE")
        let quick = ["CADENCE_BUSY_TIMEOUT_MS": "200"]
        let write = try cli.run(["log", "Fixed the secret flaky test"], environment: quick)
        #expect(write.status == 3)
        #expect(write.stderr.hasPrefix("cadence: "))
        // Titles never reach stderr.
        #expect(!write.stderr.contains("secret"))
        let read = try cli.run(["today", "--json"], environment: quick)
        #expect(read.status == 0)
        try blocker.execute("ROLLBACK")
        #expect(try cli.run(["log", "Fixed the secret flaky test"], environment: quick).status == 0)
    }
}
