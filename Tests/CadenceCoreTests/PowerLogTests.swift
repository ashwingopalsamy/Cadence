import Foundation
import Testing

@testable import CadenceCore

@Suite struct PowerLogTests {
    static let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    static let newYork = TimeZone(identifier: "America/New_York")!

    static func fixture(_ name: String) throws -> String {
        let url = Vectors.root.appendingPathComponent("pmset/\(name)")
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    static func noon(_ day: String, in zone: TimeZone) -> Date {
        Timestamp.resolve(LocalDate(day)!, hour: 12, minute: 0, in: zone)
    }

    static func parse(_ name: String, zone: TimeZone = kolkata, today: String = "2026-11-05") throws -> PowerLogResult {
        let parser = PowerLogParser(zone: zone, boundary: .standard)
        return parser.parse(try fixture(name), now: noon(today, in: zone))
    }

    /// "day start-end" in local time, for readable expectations.
    static func shown(_ result: PowerLogResult, zone: TimeZone = kolkata) -> [String] {
        result.spans.map {
            "\($0.day) \(Timestamp.local($0.start, in: zone).dropFirst(11))-\(Timestamp.local($0.end, in: zone).dropFirst(11))"
        }
    }

    @Test func normalDay() throws {
        let result = try Self.parse("normal-day.log")
        #expect(
            Self.shown(result) == [
                "2026-10-27 09:05:12+05:30-12:30:00+05:30", "2026-10-27 13:10:44+05:30-18:20:09+05:30",
            ])
        #expect(result.malformed == 0)
    }

    @Test func overnightSplitsAtTheBoundary() throws {
        let result = try Self.parse("overnight.log")
        // Awake 22:00 to 03:30, display off, on again 03:45, sleep 05:30. The boundary at 04:00 splits the last part.
        #expect(
            Self.shown(result) == [
                "2026-10-27 22:00:03+05:30-03:30:00+05:30", "2026-10-27 03:45:00+05:30-04:00:00+05:30",
                "2026-10-28 04:00:00+05:30-05:30:00+05:30",
            ])
        for span in result.spans {
            let payload = PresenceSpanPayload(
                day: span.day.description, tz: Self.kolkata.identifier,
                start: Timestamp.local(span.start, in: Self.kolkata), end: Timestamp.local(span.end, in: Self.kolkata),
                source: .powerlog)
            #expect(throws: Never.self) { _ = try PresenceSpanPayload(json: payload.json) }
        }
    }

    @Test func darkWakeIsIgnored() throws {
        let result = try Self.parse("darkwake-noise.log")
        // The DarkWake lines open nothing. The display turning on at 09:52 does start presence, and the
        // maintenance sleep closes it at 09:58.
        #expect(
            Self.shown(result) == [
                "2026-10-27 09:00:00+05:30-09:40:00+05:30", "2026-10-27 09:52:40+05:30-09:58:00+05:30",
                "2026-10-27 14:00:00+05:30-15:00:00+05:30",
            ])
    }

    @Test func displayOnAndOff() throws {
        let result = try Self.parse("display.log")
        // The 30 second blink at 11:20 is dropped; the duplicate on and off lines change nothing.
        #expect(
            Self.shown(result) == [
                "2026-10-27 09:00:00+05:30-11:00:00+05:30", "2026-10-27 12:00:00+05:30-13:00:00+05:30",
            ])
    }

    @Test func daylightSavingDay() throws {
        let result = try Self.parse("dst-new-york.log", zone: Self.newYork)
        #expect(
            Self.shown(result, zone: Self.newYork) == [
                "2026-10-31 20:00:00-04:00-00:30:00-04:00", "2026-10-31 00:45:00-04:00-01:30:00-05:00",
                "2026-11-01 08:00:00-05:00-17:00:00-05:00",
            ])
        // The fall-back hour counts: 00:45 EDT to 01:30 EST is 105 minutes of real time.
        let second = result.spans[1]
        #expect(second.end.timeIntervalSince(second.start) == 105 * 60)
        #expect(result.spans[0].day == LocalDate("2026-10-31"))
        #expect(result.spans[1].day == LocalDate("2026-10-31"))
        #expect(result.spans[2].day == LocalDate("2026-11-01"))
    }

    @Test func malformedLinesAreSkippedAndCounted() throws {
        let result = try Self.parse("malformed.log")
        #expect(Self.shown(result) == ["2026-10-27 09:00:00+05:30-12:00:00+05:30"])
        #expect(result.malformed == 4)
    }

    @Test func unsortedInputIsSortedByInstant() {
        let text = """
            2026-10-27 12:00:00 +0530 Sleep\tx
            2026-10-27 09:00:00 +0530 Wake\tx
            2026-10-27 09:00:00 +0530 Wake\tduplicate
            """
        let result = PowerLogParser(zone: Self.kolkata, boundary: .standard).parse(
            text, now: Self.noon("2026-11-05", in: Self.kolkata))
        #expect(Self.shown(result) == ["2026-10-27 09:00:00+05:30-12:00:00+05:30"])
    }

    @Test func mixedOffsetsAreInstants() {
        // 09:00 +0530 is 03:30 UTC; 08:30 +0100 is 07:30 UTC.
        let text = "2026-10-27 09:00:00 +0530 Wake\tx\n2026-10-27 08:30:00 +0100 Sleep\tx\n"
        let result = PowerLogParser(zone: Self.kolkata, boundary: .standard).parse(
            text, now: Self.noon("2026-11-05", in: Self.kolkata))
        #expect(result.spans.count == 1)
        #expect(result.spans[0].end.timeIntervalSince(result.spans[0].start) == 4 * 3600)
    }

    @Test func unterminatedIntervalIsDroppedUnlessToday() {
        let text = "2026-10-27 09:00:00 +0530 Wake\tx\n"
        let parser = PowerLogParser(zone: Self.kolkata, boundary: .standard)
        let later = parser.parse(text, now: Self.noon("2026-10-29", in: Self.kolkata))
        #expect(later.spans.isEmpty)
        let sameDay = parser.parse(text, now: Self.noon("2026-10-27", in: Self.kolkata).addingTimeInterval(3 * 3600))
        #expect(Self.shown(sameDay) == ["2026-10-27 09:00:00+05:30-15:00:00+05:30"])
    }

    @Test func secondWakeWithoutSleepKeepsOneInterval() {
        let text = """
            2026-10-27 09:00:00 +0530 Wake\tx
            2026-10-27 13:00:00 +0530 Wake\tx
            2026-10-27 14:00:00 +0530 Sleep\tx
            """
        let result = PowerLogParser(zone: Self.kolkata, boundary: .standard).parse(
            text, now: Self.noon("2026-11-05", in: Self.kolkata))
        #expect(Self.shown(result) == ["2026-10-27 09:00:00+05:30-14:00:00+05:30"])
    }

    @Test func eventsAfterNowAreIgnored() {
        let text = "2026-10-27 09:00:00 +0530 Wake\tx\n2026-10-27 12:00:00 +0530 Sleep\tx\n"
        let now = Timestamp.resolve(LocalDate("2026-10-27")!, hour: 10, minute: 0, in: Self.kolkata)
        let result = PowerLogParser(zone: Self.kolkata, boundary: .standard).parse(text, now: now)
        #expect(Self.shown(result) == ["2026-10-27 09:00:00+05:30-10:00:00+05:30"])
    }

    @Test func dayTable() throws {
        let result = try Self.parse("normal-day.log")
        let table = PowerLogDay.summarize(result.spans, in: Self.kolkata)
        #expect(table.count == 1)
        #expect(table[0].day == LocalDate("2026-10-27"))
        #expect(table[0].first == "2026-10-27T09:05:12+05:30")
        #expect(table[0].last == "2026-10-27T18:20:09+05:30")
        #expect(table[0].spans == 2)
    }
}
