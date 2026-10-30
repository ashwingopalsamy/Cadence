import Foundation
import Testing

@testable import CadenceCore

/// docs/SPEC.md section 10.3 against synthetic recorded gh output in Tests/Vectors/github.
@Suite struct GitHubCollectorTests {
    static let now = Timestamp.parse("2026-10-30T10:00:00Z")!
    static let gh = "/opt/example/bin/gh"

    /// A runner that answers from a handler and remembers every request.
    final class FakeRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [ProcessRequest] = []
        let handler: @Sendable (ProcessRequest) throws -> ProcessResult

        init(_ handler: @escaping @Sendable (ProcessRequest) throws -> ProcessResult) { self.handler = handler }

        var requests: [ProcessRequest] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        func run(_ request: ProcessRequest) throws -> ProcessResult {
            lock.lock()
            seen.append(request)
            lock.unlock()
            return try handler(request)
        }
    }

    static func ok(_ text: String) -> ProcessResult {
        ProcessResult(termination: .exited(0), timedOut: false, stdout: Data(text.utf8), stdoutTruncated: false, stderrTail: Data())
    }

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: Vectors.root.appendingPathComponent("github/\(name)"), encoding: .utf8)
    }

    static func variable(_ request: ProcessRequest, _ key: String) -> String? {
        var i = 0
        while i + 1 < request.arguments.count {
            if request.arguments[i] == "-f", request.arguments[i + 1].hasPrefix(key + "=") {
                return String(request.arguments[i + 1].dropFirst(key.count + 1))
            }
            i += 1
        }
        return nil
    }

    /// The recorded run: two contribution pages, then two search pages.
    static func recorded() throws -> FakeRunner {
        let c1 = try fixture("contributions-1.json"), c2 = try fixture("contributions-2.json")
        let s1 = try fixture("search-1.json"), s2 = try fixture("search-2.json")
        return FakeRunner { request in
            if variable(request, "q") != nil { return ok(variable(request, "cursor") == nil ? s1 : s2) }
            return ok(variable(request, "prs") == nil ? c1 : c2)
        }
    }

    static func collector(
        _ runner: FakeRunner, gh: String = gh, environment: [String: String] = ["GH_HOST": "git.example.com"],
        config: Config = Config.defaults(timezone: "Asia/Kolkata")
    ) -> GitHubCollector {
        GitHubCollector(
            gh: gh, runner: runner, environment: environment, workingDirectory: FileManager.default.temporaryDirectory,
            config: config, clock: ManualClock(now), random: SeededRandomSource(seed: 7))
    }

    static func records(_ bytes: [UInt8]) throws -> (header: JSONValue, items: [JSONValue]) {
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n").map(String.init)
        let values = try lines.map { try JSONParser.parse($0) }
        return (values[0], Array(values.dropFirst()))
    }

    static func item(_ items: [JSONValue], _ ref: String) -> JSONValue? {
        items.first { $0["source_ref"]?.stringValue == ref }
    }

    static let window = (since: "2026-10-26", until: "2026-10-29")

    // MARK: - Mapping

    @Test func headerNamesTheCollectorRunAndWindow() throws {
        let bytes = try Self.collector(Self.recorded()).envelope(since: Self.window.since, until: Self.window.until)
        let (header, _) = try Self.records(bytes)
        #expect(header["cadence"] == "envelope/1" && header["collector"] == "github")
        #expect(header["generated_at"] == "2026-10-30T15:30:00+05:30")
        #expect(header["window"] == ["since": "2026-10-26", "until": "2026-10-29"])
        #expect(ULID.isValid(try #require(header["run"]?.stringValue)))
        #expect(bytes.last == 0x0A)

        let named = try GitHubCollector(
            name: "github-work", gh: Self.gh, runner: Self.recorded(), environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory, config: Config.defaults(timezone: "Asia/Kolkata"),
            clock: ManualClock(Self.now)
        ).envelope(since: "2026-10-26", until: "2026-10-29")
        #expect(try Self.records(named).header["collector"] == "github-work")
    }

    @Test func opensMergesAndReviewsBecomeRecords() throws {
        let (_, items) = try Self.records(Self.collector(Self.recorded()).envelope(since: Self.window.since, until: Self.window.until))
        #expect(items.count == 9)
        #expect(items.allSatisfy { $0["type"] == "item" && $0["ticket"] == nil })
        let times = items.compactMap { $0["occurred_at"]?.stringValue }
        #expect(times == times.sorted())

        let opened = try #require(Self.item(items, "github:PR_acme001:opened"))
        #expect(opened["kind"] == "pr.opened" && opened["occurred_at"] == "2026-10-27T10:30:00+05:30")
        #expect(opened["title"] == "ACME-482913 Ship retry budget for capture path")
        #expect(opened["links"] == [["kind": "pr", "url": "https://git.example.com/acme/ledger-core/pull/412"]])
        #expect(opened["attrs"] == [
            "repo": "acme/ledger-core", "number": 412, "additions": 184, "deletions": 37, "ai_assisted": true, "draft": false,
        ])

        let draft = try #require(Self.item(items, "github:PR_acme002:opened"))
        #expect(draft["attrs"]?["draft"] == true && draft["attrs"]?["ai_assisted"] == false)

        let merged = try #require(Self.item(items, "github:PR_acme001:merged"))
        #expect(merged["kind"] == "pr.merged" && merged["occurred_at"] == "2026-10-29T16:02:11+05:30")
        #expect(merged["attrs"] == ["repo": "acme/ledger-core", "number": 412, "additions": 184, "deletions": 37, "ai_assisted": true])

        let plain = try #require(Self.item(items, "github:PR_acme005:merged"))
        #expect(plain["attrs"]?["ai_assisted"] == false)
        #expect(Self.item(items, "github:PR_acme004:merged") == nil, "merged before the window")
        #expect(Self.item(items, "github:PR_acme003:opened")?["attrs"]?["ai_assisted"] == true, "marker matches case-insensitively")
    }

    @Test func reviewsGroupPerPullRequestPerLocalDay() throws {
        let (_, items) = try Self.records(Self.collector(Self.recorded()).envelope(since: Self.window.since, until: Self.window.until))
        let reviews = items.filter { $0["kind"] == "review.given" }
        #expect(reviews.count == 4)

        let day = try #require(Self.item(items, "github:review:PR_acme088:2026-10-28"))
        #expect(day["occurred_at"] == "2026-10-28T11:20:40+05:30", "the first review of the day")
        #expect(day["attrs"] == ["repo": "acme/refunds", "number": 88, "reviews": 2, "comments": 6, "state": "APPROVED"])
        #expect(day["title"] == "ACME-482100 Idempotency keys for refunds")

        // 03:30 is before the 04:00 boundary, so it still belongs to the 28th; 04:30 belongs to the 29th.
        let late = try #require(Self.item(items, "github:review:PR_acme090:2026-10-28"))
        #expect(late["occurred_at"] == "2026-10-29T03:30:00+05:30" && late["attrs"]?["reviews"] == 1)
        let next = try #require(Self.item(items, "github:review:PR_acme090:2026-10-29"))
        #expect(next["attrs"]?["comments"] == 3 && next["attrs"]?["state"] == "CHANGES_REQUESTED")

        #expect(Self.item(items, "github:review:PR_acme002:2026-10-28") == nil, "reviews on your own pull requests are skipped")
        #expect(Self.item(items, "github:review:PR_acme091:2026-10-28") != nil, "a deleted author is not you")
    }

    @Test func aDifferentDayBoundaryMovesTheReviewDay() throws {
        var config = Config.defaults(timezone: "Asia/Kolkata")
        config.dayBoundary = try #require(DayBoundary(hour: 0, minute: 0))
        let (_, items) = try Self.records(Self.collector(Self.recorded(), config: config).envelope(since: "2026-10-26", until: "2026-10-29"))
        #expect(Self.item(items, "github:review:PR_acme090:2026-10-29") != nil)
        #expect(Self.item(items, "github:review:PR_acme090:2026-10-28") == nil)
    }

    @Test func aiMarkersComeFromConfig() throws {
        var config = Config.defaults(timezone: "Asia/Kolkata")
        config.aiMarkers = ["written by hand"]
        let (_, items) = try Self.records(Self.collector(Self.recorded(), config: config).envelope(since: "2026-10-26", until: "2026-10-29"))
        #expect(Self.item(items, "github:PR_acme001:opened")?["attrs"]?["ai_assisted"] == false)
        #expect(Self.item(items, "github:PR_acme002:opened")?["attrs"]?["ai_assisted"] == true)
    }

    @Test func nothingPrivateIsEmitted() throws {
        let text = String(decoding: try Self.collector(Self.recorded()).envelope(since: Self.window.since, until: Self.window.until), as: UTF8.self)
        for secret in ["example-colleague", "acme-dev", "bodyText", "Generated with", "Adds a retry budget", "Plain body", "\"author\"", "login"] {
            #expect(!text.contains(secret), "\(secret) must not be emitted")
        }
    }

    // MARK: - What is asked of gh

    @Test func pagesAreRequestedWithTheCursorsAndNothingElseIsPassedToGh() throws {
        let runner = try Self.recorded()
        let env = [
            "GH_HOST": "git.example.com", "HOME": "/home/example", "PATH": "/usr/bin", "LANG": "en_US.UTF-8", "TZ": "Asia/Kolkata",
            "GH_TOKEN": "not-a-real-token", "GITHUB_TOKEN": "nope", "AWS_SECRET": "nope",
        ]
        _ = try Self.collector(runner, environment: env).envelope(since: Self.window.since, until: Self.window.until)

        let requests = runner.requests
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.executable == Self.gh && Array($0.arguments.prefix(3)) == ["api", "graphql", "-f"] })
        #expect(requests.allSatisfy { Set($0.environment.keys) == ["GH_HOST", "HOME", "PATH", "LANG", "TZ"] })
        #expect(requests.allSatisfy { $0.environment["GH_HOST"] == "git.example.com" && $0.stdin == nil })

        #expect(Self.variable(requests[0], "prs") == nil && Self.variable(requests[0], "reviews") == nil)
        #expect(Self.variable(requests[0], "from") == "2026-10-25T22:30:00.000Z")
        #expect(Self.variable(requests[0], "to") == "2026-10-29T22:30:00.000Z")
        #expect(Self.variable(requests[1], "prs") == "PRS1" && Self.variable(requests[1], "reviews") == "REV1")
        #expect(requests[0].arguments.contains { $0.hasPrefix("query=") && $0.contains("pullRequestReviewContributions(first: 100") })

        // The search is padded by a day each side (merged: works on UTC days); mergedAt is then checked exactly.
        #expect(Self.variable(requests[2], "q") == "is:pr author:acme-dev merged:2026-10-24..2026-10-30")
        #expect(Self.variable(requests[2], "cursor") == nil)
        #expect(Self.variable(requests[3], "cursor") == "SRCH1")
    }

    @Test func aConnectionThatFinishedEarlyIsNotReadAgain() throws {
        @Sendable func page(prs: Bool, reviews: Bool) -> String {
            let pr = #"{"pullRequest":{"id":"PR_one","number":1,"title":"Only once","url":"https://git.example.com/acme/web-app/pull/1","isDraft":false,"createdAt":"2026-10-27T05:00:00Z","additions":1,"deletions":0,"bodyText":"","repository":{"nameWithOwner":"acme/web-app"}}}"#
            let review = #"{"pullRequestReview":{"id":"PRR_\#(reviews ? "a" : "b")","state":"APPROVED","submittedAt":"2026-10-27T06:00:00Z","comments":{"totalCount":1}},"pullRequest":{"id":"PR_two","number":2,"title":"Other","url":"https://git.example.com/acme/web-app/pull/2","author":{"login":"example-colleague"},"repository":{"nameWithOwner":"acme/web-app"}}}"#
            return #"{"data":{"viewer":{"login":"acme-dev","contributionsCollection":{"pullRequestContributions":{"pageInfo":{"hasNextPage":false,"endCursor":"P"},"nodes":[\#(pr)]},"pullRequestReviewContributions":{"pageInfo":{"hasNextPage":\#(reviews),"endCursor":"R"},"nodes":[\#(review)]}}}}}"#
        }
        let runner = FakeRunner { request in
            if Self.variable(request, "q") != nil { return Self.ok(#"{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#) }
            return Self.ok(page(prs: false, reviews: Self.variable(request, "reviews") == nil))
        }
        let (_, items) = try Self.records(Self.collector(runner).envelope(since: Self.window.since, until: Self.window.until))
        #expect(items.filter { $0["kind"] == "pr.opened" }.count == 1)
        #expect(items.filter { $0["kind"] == "review.given" }.count == 1)
        #expect(Self.item(items, "github:review:PR_two:2026-10-27")?["attrs"]?["reviews"] == 2)
    }

    @Test func windowsAcceptDaysAndTimes() throws {
        let runner = try Self.recorded()
        _ = try Self.collector(runner).envelope(since: "2026-10-26T09:00:00+05:30", until: "2026-10-29T12:00:00Z")
        #expect(Self.variable(runner.requests[0], "from") == "2026-10-26T03:30:00.000Z")
        #expect(Self.variable(runner.requests[0], "to") == "2026-10-29T12:00:00.000Z")
    }

    @Test func badWindowsAndPathsAreRefusedBeforeGhRuns() throws {
        let runner = try Self.recorded()
        for (since, until) in [("yesterday", "2026-10-29"), ("2026-10-26", "2026-10-26T99"), ("2026-10-29", "2026-10-26")] {
            #expect(throws: CadenceError.self) { try Self.collector(runner).envelope(since: since, until: until) }
        }
        #expect(throws: CadenceError.self) { try Self.collector(runner, gh: "gh").envelope(since: "2026-10-26", until: "2026-10-29") }
        #expect(runner.requests.isEmpty)
    }

    // MARK: - Failures

    func expectFailure(_ result: ProcessResult, mentioning words: String..., sourceLocation: SourceLocation = #_sourceLocation) {
        let runner = FakeRunner { _ in result }
        do {
            _ = try Self.collector(runner).envelope(since: Self.window.since, until: Self.window.until)
            Issue.record("expected a failure", sourceLocation: sourceLocation)
        } catch {
            for word in words { #expect(error.message.contains(word), "'\(error.message)' should mention \(word)", sourceLocation: sourceLocation) }
        }
    }

    @Test func ghFailuresAreReadableAndFatal() throws {
        expectFailure(
            ProcessResult(termination: .exited(1), timedOut: false, stdout: Data(), stdoutTruncated: false,
                          stderrTail: Data("gh: To use GitHub CLI, run: gh auth login\n".utf8)),
            mentioning: "status 1", "gh auth login")
        expectFailure(
            ProcessResult(termination: .signalled(15), timedOut: true, stdout: Data(), stdoutTruncated: false, stderrTail: Data()),
            mentioning: "timed out")
        var truncated = Self.ok(try Self.fixture("contributions-1.json"))
        truncated.stdoutTruncated = true
        expectFailure(truncated, mentioning: "more than the allowed")
        expectFailure(Self.ok("{\"data\":{\"viewer\":"), mentioning: "not valid JSON")
        expectFailure(Self.ok("[]"), mentioning: "no data")
        expectFailure(
            Self.ok(#"{"data":null,"errors":[{"message":"Resource not accessible by integration"}]}"#),
            mentioning: "GitHub returned errors", "Resource not accessible")
        expectFailure(
            Self.ok(#"{"data":{"viewer":{"login":"acme-dev"}},"errors":[{"message":"partial"}]}"#), mentioning: "partial")
    }

    @Test func aFailureOnALaterPageDiscardsEverything() throws {
        let c1 = try Self.fixture("contributions-1.json")
        let runner = FakeRunner { request in
            Self.variable(request, "prs") == nil
                ? Self.ok(c1)
                : ProcessResult(termination: .exited(1), timedOut: false, stdout: Data(), stdoutTruncated: false, stderrTail: Data("boom".utf8))
        }
        #expect(throws: CadenceError.self) { try Self.collector(runner).envelope(since: "2026-10-26", until: "2026-10-29") }
    }

    @Test func floatsInFieldsWeDoNotReadDoNotFailTheRun() throws {
        // search-2.json carries "extensions": {"cost": {"score": 1.5, "limit": 5e3}}.
        let (_, items) = try Self.records(Self.collector(Self.recorded()).envelope(since: Self.window.since, until: Self.window.until))
        #expect(Self.item(items, "github:PR_acme005:merged") != nil)

        let scrubbed = GitHubGraphQL.scrubNumbers(Array(#"{"a":1.5,"b":[2e3,-0.5,7],"s":"1.5e9 \"3.5\"","t":true,"id":12345678901234567890}"#.utf8))
        #expect(try JSONParser.parse(bytes: scrubbed) == ["a": 0, "b": [0, 0, 7], "s": "1.5e9 \"3.5\"", "t": true, "id": 0])
    }

    // MARK: - Through the real ingester

    @Test func theEnvelopeIngestsAndASecondRunChangesNothing() throws {
        let clock = ManualClock(Self.now)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let journal = try Journal(
            store: store, config: Config.defaults(timezone: "Asia/Kolkata"), clock: clock, ids: CountingIDs())
        let window = IngestWindow(since: Self.window.since, until: Self.window.until)
        let collector = try Self.collector(Self.recorded())

        let first = try journal.ingest(
            envelope: collector.envelope(since: window.since, until: window.until), collector: "github", window: window)
        #expect(first.status == "ok")
        #expect(first.counts["records"] == 9 && first.counts["created"] == 9)
        #expect(first.counts["skipped"] == 0 && first.counts["warnings"] == 0, "\(first.problems)")

        func entry(_ ref: String) throws -> Entry {
            let id = try #require(try store.db.query("SELECT id FROM entries WHERE source_ref = ?", [.text(ref)]).first?.text("id"))
            return try journal.entry(id)
        }
        let merged = try entry("github:PR_acme001:merged")
        #expect(merged.title == "Ship retry budget for capture path")
        #expect(merged.ticket == Ticket(key: "ACME-482913", class: .assigned))
        #expect(merged.family == .delivery && merged.kind == .prMerged)
        #expect(merged.origin == .collected && merged.source == "github" && merged.day == "2026-10-29")
        #expect(merged.attrs["ai_assisted"] == true)

        let draft = try entry("github:PR_acme002:opened")
        #expect(draft.ticket == Ticket(key: "ACME-000000", class: .selfInitiated) && draft.family == .initiative)
        #expect(try entry("github:PR_acme003:opened").ticket == nil)

        let review = try entry("github:review:PR_acme088:2026-10-28")
        #expect(review.kind == .reviewGiven && review.family == .review && review.day == "2026-10-28")
        #expect(review.attrs["reviews"] == 2 && review.attrs["comments"] == 6)
        #expect(try entry("github:review:PR_acme090:2026-10-28").day == "2026-10-28")
        #expect(try entry("github:review:PR_acme090:2026-10-29").day == "2026-10-29")

        let again = try journal.ingest(
            envelope: collector.envelope(since: window.since, until: window.until), collector: "github", window: window)
        #expect(again.counts["unchanged"] == 9 && again.counts["created"] == 0 && again.counts["updated"] == 0)
    }
}
