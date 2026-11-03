import CadenceCore
import Foundation
import Testing

/// `cadence day reopen` and `cadence day history` (docs/SPEC.md sections 3 and 9.5): the real binary against its own home.
@Suite struct ReopenCommandTests {
    let cli = CLIHome()

    @Test func aSealedDayIsReopenedAndSealedAgainWithItsHistory() throws {
        defer { cli.remove() }
        let today = try cli.today()
        try cli.run(["log", "Fixed the flaky test"])
        let sealed = try cli.json(["day", "seal"])
        let firstSeal = try #require(sealed["sealed_at"]?.stringValue)

        let reopened = try cli.json(["day", "reopen"])
        #expect(reopened["day"]?.stringValue == today.description)
        #expect(reopened["sealed_at"]?.stringValue == firstSeal)
        #expect(reopened["reopened_at"]?.stringValue?.contains("T") == true)
        #expect(reopened["streak"]?["current"] != nil && reopened["streak"]?["best"] != nil)
        #expect(try cli.json(["day", "show"])["day"]?["sealed_at"] == .null)

        // The day reads as unsealed, so the usual command seals it again.
        let again = try cli.json(["day", "seal"])
        #expect(again["day"]?.stringValue == today.description)
        #expect(again["counts_for_streak"]?.boolValue == true)
        // `day show` prints the recorded time and `day seal` the same instant in the profile zone, to the second.
        let shown = try #require(try cli.json(["day", "show"])["day"]?["sealed_at"]?.stringValue.flatMap { Timestamp.parse($0) })
        let sealedAgain = try #require(again["sealed_at"]?.stringValue.flatMap { Timestamp.parse($0) })
        #expect(abs(shown.timeIntervalSince(sealedAgain)) < 1)

        let history = try cli.json(["day", "history"])
        #expect(history["day"]?.stringValue == today.description)
        let items = try #require(history["history"]?.arrayValue)
        #expect(items.compactMap { $0["kind"]?.stringValue } == ["sealed", "reopened", "sealed"])
        #expect(items.allSatisfy { $0["actor"]?.stringValue == "cli" && $0["at"]?.stringValue?.contains("T") == true })
        #expect(items[0]["at"]?.stringValue == firstSeal)
        #expect(items[2]["at"]?.stringValue == again["sealed_at"]?.stringValue)
    }

    @Test func reopeningADayThatIsNotSealedIsRefused() throws {
        defer { cli.remove() }
        let today = try cli.today()
        let refused = try cli.run(["day", "reopen"])
        #expect(refused.status == 2)
        #expect(refused.stdout.isEmpty)
        #expect(refused.stderr == "cadence: \(today) is not wrapped up, so there is nothing to reopen\n")
        let yesterday = today.adding(days: -1)
        #expect(try cli.run(["day", "reopen", "--date", yesterday.description]).status == 2)
        #expect(try cli.run(["day", "reopen", "--date", today.adding(days: 1).description]).status == 2)
        #expect(try cli.run(["day", "reopen", "--date", "nope"]).status == 2)

        // Once reopened, a second reopen is refused the same way.
        try cli.run(["day", "seal"])
        #expect(try cli.run(["day", "reopen"]).status == 0)
        #expect(try cli.run(["day", "reopen"]).status == 2)
    }

    @Test func aPastDayCanBeReopenedWithDate() throws {
        defer { cli.remove() }
        let yesterday = try cli.today().adding(days: -1)
        try cli.run(["log", "Fixed it yesterday", "--date", yesterday.description])
        try cli.run(["day", "seal", "--date", yesterday.description])
        let reopened = try cli.json(["day", "reopen", "--date", yesterday.description])
        #expect(reopened["day"]?.stringValue == yesterday.description)
        let history = try cli.json(["day", "history", "--date", yesterday.description])
        #expect(history["history"]?.arrayValue?.compactMap { $0["kind"]?.stringValue } == ["sealed", "reopened"])
    }

    @Test func humanOutputIsPlainSentenceCase() throws {
        defer { cli.remove() }
        try cli.run(["day", "seal"])
        let reopened = try cli.run(["day", "reopen"])
        #expect(reopened.status == 0)
        #expect(reopened.stdout.hasPrefix("Reopened "))
        #expect(reopened.stdout.contains("It was wrapped up at "))
        #expect(reopened.stdout.contains("Streak "))
        try cli.run(["day", "seal"])
        let history = try cli.run(["day", "history"])
        #expect(history.status == 0)
        let lines = history.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[1].hasPrefix("Sealed ") && lines[2].hasPrefix("Reopened ") && lines[3].hasPrefix("Sealed again "))
        for text in [reopened.stdout, history.stdout] {
            #expect(!text.contains("\u{2013}") && !text.contains("\u{2014}"))
        }
    }

    @Test func aDayWithNoWrapUpHasNoHistory() throws {
        defer { cli.remove() }
        let today = try cli.today()
        let json = try cli.json(["day", "history"])
        #expect(json["history"]?.arrayValue?.isEmpty == true)
        let human = try cli.run(["day", "history"])
        #expect(human.status == 0)
        #expect(human.stdout == "No wrap-up history for \(today).\n")
    }

    @Test func aSealMadeLongAfterTheGraceWindowStillCounts() throws {
        defer { cli.remove() }
        let today = try cli.today()
        let old = today.adding(days: -10)
        let other = today.adding(days: -9)
        try cli.run(["log", "Backfilled work", "--date", old.description])
        let sealed = try cli.json(["day", "seal", "--date", old.description])
        #expect(sealed["counts_for_streak"]?.boolValue == true)
        let human = try cli.run(["day", "seal", "--date", other.description])
        #expect(human.status == 0)
        #expect(human.stdout.hasPrefix("Wrapped up \(other) at "))
        #expect(!human.stdout.contains("grace") && !human.stdout.contains("does not count"))
    }
}
