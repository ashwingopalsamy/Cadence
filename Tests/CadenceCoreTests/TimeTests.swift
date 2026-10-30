import Foundation
import Testing

@testable import CadenceCore

private func zone(_ id: String) -> TimeZone {
    TimeZone(identifier: id)!
}

private func instant(_ text: String) -> Date {
    Timestamp.parse(text)!
}

private func date(_ text: String) -> LocalDate {
    LocalDate(text)!
}

@Suite struct TimeTests {
    // MARK: LocalDate

    @Test func localDateParsesAndFormats() {
        #expect(LocalDate("2026-10-01")?.description == "2026-10-01")
        #expect(LocalDate("2026-10-01")?.year == 2026)
        #expect(LocalDate("2026-10-01")?.month == 10)
        #expect(LocalDate("2026-10-01")?.day == 1)
        #expect(LocalDate(year: 2026, month: 1, day: 5)?.description == "2026-01-05")
    }

    @Test func localDateRejectsInvalid() {
        for bad in [
            "2026-02-29", "2026-13-01", "2026-1-01", " 2026-10-01", "2026-10-01 ", "2026-00-10",
            "2026-10-00", "2026-04-31", "26-10-01", "2026/10/01", "", "2026-10-011", "0999-01-01",
            "+026-10-01", "2026-1a-01", "２０２６-10-01",
        ] {
            #expect(LocalDate(bad) == nil, "\(bad)")
        }
        #expect(LocalDate(year: 2026, month: 2, day: 29) == nil)
        #expect(LocalDate(year: 10000, month: 1, day: 1) == nil)
    }

    @Test func localDateLeapYears() {
        #expect(LocalDate("2028-02-29") != nil)
        #expect(LocalDate("2000-02-29") != nil)
        #expect(LocalDate("1900-02-29") == nil)
        #expect(LocalDate("2100-02-29") == nil)
    }

    @Test func localDateArithmetic() {
        #expect(date("2026-01-31").adding(days: 1).description == "2026-02-01")
        #expect(date("2026-12-31").adding(days: 1).description == "2027-01-01")
        #expect(date("2028-02-28").adding(days: 1).description == "2028-02-29")
        #expect(date("2026-03-01").adding(days: -1).description == "2026-02-28")
        #expect(date("2026-01-01").adding(days: -1).description == "2025-12-31")
        #expect(date("2026-10-30").adding(days: 0) == date("2026-10-30"))
        #expect(date("2026-01-01").adding(days: 365).description == "2027-01-01")
        #expect(date("2026-10-01").days(until: date("2026-10-30")) == 29)
        #expect(date("2026-10-30").days(until: date("2026-10-01")) == -29)
        #expect(date("2025-12-31").days(until: date("2027-01-01")) == 366)
        #expect(date("2026-10-01") < date("2026-10-02"))
        #expect(date("2025-12-31") < date("2026-01-01"))
    }

    @Test func localDateWeekday() {
        #expect(date("2026-10-01").weekday == .thu)
        #expect(date("2026-10-30").weekday == .fri)
        #expect(date("1970-01-01").weekday == .thu)
        #expect(date("2026-10-04").weekday == .sun)
        #expect(date("2026-10-05").weekday == .mon)
        #expect(date("2028-02-29").weekday == .tue)
        #expect(date("2026-10-03").weekday == .sat)
    }

    @Test func localDateRange() {
        let days = LocalDate.range(date("2026-02-27"), through: date("2026-03-02"))
        #expect(days.map(\.description) == ["2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02"])
        #expect(LocalDate.range(date("2026-10-01"), through: date("2026-10-01")).count == 1)
        #expect(LocalDate.range(date("2026-10-02"), through: date("2026-10-01")).isEmpty)
    }

    @Test func weekdayRawValues() {
        #expect(Weekday.allCases.map(\.rawValue) == ["mon", "tue", "wed", "thu", "fri", "sat", "sun"])
    }

    // MARK: DayBoundary

    @Test func boundaryParsing() {
        #expect(DayBoundary("04:00") == DayBoundary.standard)
        #expect(DayBoundary("00:00")?.hour == 0)
        #expect(DayBoundary("23:59")?.minute == 59)
        for bad in ["4:00", "24:00", "04:60", "04:0", "0400", "04:00:00", " 04:00", "-1:00", "ab:cd", ""] {
            #expect(DayBoundary(bad) == nil, "\(bad)")
        }
        #expect(DayBoundary(hour: 24, minute: 0) == nil)
        #expect(DayBoundary(hour: 4, minute: 60) == nil)
        #expect(DayBoundary(hour: -1, minute: 0) == nil)
    }

    @Test func boundaryDayInKolkata() {
        let kolkata = zone("Asia/Kolkata")
        let b = DayBoundary.standard
        #expect(b.day(of: instant("2026-10-29T03:59:00+05:30"), in: kolkata) == date("2026-10-28"))
        #expect(b.day(of: instant("2026-10-29T04:00:00+05:30"), in: kolkata) == date("2026-10-29"))
        #expect(b.day(of: instant("2026-10-29T23:59:00+05:30"), in: kolkata) == date("2026-10-29"))
        #expect(b.day(of: instant("2026-10-30T02:30:00+05:30"), in: kolkata) == date("2026-10-29"))
        #expect(b.day(of: instant("2026-10-30T00:00:00+05:30"), in: kolkata) == date("2026-10-29"))
    }

    @Test func customBoundaries() {
        let kolkata = zone("Asia/Kolkata")
        let midnight = DayBoundary(hour: 0, minute: 0)
        #expect(midnight?.day(of: instant("2026-10-30T00:00:00+05:30"), in: kolkata) == date("2026-10-30"))
        #expect(midnight?.day(of: instant("2026-10-29T23:59:59+05:30"), in: kolkata) == date("2026-10-29"))
        let six = DayBoundary("06:30")
        #expect(six?.day(of: instant("2026-10-30T06:29:00+05:30"), in: kolkata) == date("2026-10-29"))
        #expect(six?.day(of: instant("2026-10-30T06:30:00+05:30"), in: kolkata) == date("2026-10-30"))
    }

    @Test func sameInstantDiffersAcrossZones() {
        let kolkata = zone("Asia/Kolkata")
        let sao = zone("America/Sao_Paulo")
        // 2026-10-29 22:30 UTC is 04:00 on the 30th in Kolkata and 19:30 on the 29th in Sao Paulo.
        let t = instant("2026-10-29T22:30:00Z")
        #expect(DayBoundary.standard.day(of: t, in: kolkata) == date("2026-10-30"))
        #expect(DayBoundary.standard.day(of: t, in: sao) == date("2026-10-29"))
    }

    @Test func intervalUsesTheZonePassed() {
        let kolkata = zone("Asia/Kolkata")
        let sao = zone("America/Sao_Paulo")
        let d = date("2026-10-29")
        let k = DayBoundary.standard.interval(of: d, in: kolkata)
        #expect(Timestamp.utc(k.start) == "2026-10-28T22:30:00.000Z")
        #expect(Timestamp.utc(k.end) == "2026-10-29T22:30:00.000Z")
        let s = DayBoundary.standard.interval(of: d, in: sao)
        #expect(Timestamp.utc(s.start) == "2026-10-29T07:00:00.000Z")
        #expect(Timestamp.utc(s.end) == "2026-10-30T07:00:00.000Z")
        // Instants at the edges map back to the day.
        #expect(DayBoundary.standard.day(of: k.start, in: kolkata) == d)
        #expect(DayBoundary.standard.day(of: k.end, in: kolkata) == d.adding(days: 1))
        #expect(DayBoundary.standard.day(of: k.end.addingTimeInterval(-1), in: kolkata) == d)
    }

    @Test func intervalLengthsAcrossUSTransitions() {
        let ny = zone("America/New_York")
        let b = DayBoundary.standard
        func hours(_ d: String) -> Double {
            let i = b.interval(of: date(d), in: ny)
            return i.end.timeIntervalSince(i.start) / 3600
        }
        #expect(hours("2026-03-07") == 23)
        #expect(hours("2026-03-08") == 24)
        #expect(hours("2026-10-31") == 25)
        #expect(hours("2026-11-01") == 24)
        #expect(hours("2026-06-15") == 24)
    }

    @Test func intervalLengthsAcrossEUTransitions() {
        let london = zone("Europe/London")
        let b = DayBoundary.standard
        func hours(_ d: String) -> Double {
            let i = b.interval(of: date(d), in: london)
            return i.end.timeIntervalSince(i.start) / 3600
        }
        #expect(hours("2026-03-28") == 23)
        #expect(hours("2026-03-29") == 24)
        #expect(hours("2026-10-24") == 25)
        #expect(hours("2026-10-25") == 24)
    }

    @Test func boundaryInSpringForwardGapUsesFirstInstantAfterGap() {
        let b = DayBoundary(hour: 2, minute: 30)
        let ny = zone("America/New_York")
        // 2026-03-08 02:30 does not exist in New York; the gap ends at 03:00 EDT = 07:00Z.
        let i = b?.interval(of: date("2026-03-08"), in: ny)
        #expect(i.map { Timestamp.utc($0.start) } == "2026-03-08T07:00:00.000Z")
        #expect(i.map { Timestamp.utc($0.end) } == "2026-03-09T06:30:00.000Z")
        let london = zone("Europe/London")
        let l = DayBoundary(hour: 1, minute: 30)?.interval(of: date("2026-03-29"), in: london)
        #expect(l.map { Timestamp.utc($0.start) } == "2026-03-29T01:00:00.000Z")
        // The previous day ends exactly where the next begins.
        let prev = b?.interval(of: date("2026-03-07"), in: ny)
        #expect(prev.map { Timestamp.utc($0.end) } == "2026-03-08T07:00:00.000Z")
    }

    @Test func boundaryInFallBackOverlapUsesFirstOccurrence() {
        let ny = zone("America/New_York")
        // 2026-11-01 01:30 happens twice; first is EDT = 05:30Z.
        let i = DayBoundary(hour: 1, minute: 30)?.interval(of: date("2026-11-01"), in: ny)
        #expect(i.map { Timestamp.utc($0.start) } == "2026-11-01T05:30:00.000Z")
        #expect(i.map { Timestamp.utc($0.end) } == "2026-11-02T06:30:00.000Z")
        let london = zone("Europe/London")
        let l = DayBoundary(hour: 1, minute: 30)?.interval(of: date("2026-10-25"), in: london)
        #expect(l.map { Timestamp.utc($0.start) } == "2026-10-25T00:30:00.000Z")
        // 02:30 is unambiguous on those days.
        let c = DayBoundary(hour: 2, minute: 30)?.interval(of: date("2026-11-01"), in: ny)
        #expect(c.map { Timestamp.utc($0.start) } == "2026-11-01T07:30:00.000Z")
    }

    // MARK: Timestamp

    @Test func utcTruncatesToMilliseconds() {
        #expect(Timestamp.utc(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
        #expect(Timestamp.utc(Date(timeIntervalSince1970: 1_793_000_000.9999)) == "2026-10-26T07:33:20.999Z")
        #expect(Timestamp.utc(instant("2026-10-29T10:32:11.123Z")) == "2026-10-29T10:32:11.123Z")
        #expect(Timestamp.utc(instant("2026-10-29T10:32:11.999Z")) == "2026-10-29T10:32:11.999Z")
        #expect(Timestamp.utc(instant("2026-10-29T10:32:11.001Z")) == "2026-10-29T10:32:11.001Z")
        #expect(Timestamp.utc(instant("2026-10-29T10:32:11.0129999Z")) == "2026-10-29T10:32:11.012Z")
    }

    @Test func utcSurvivesEveryMillisecond() {
        let base = 1_793_000_000.0
        for ms in 0..<1000 {
            let d = Date(timeIntervalSince1970: base + Double(ms) / 1000)
            let digits = String(ms)
            let expected = "2026-10-26T07:33:20." + String(repeating: "0", count: 3 - digits.count) + digits + "Z"
            #expect(Timestamp.utc(d) == expected)
        }
    }

    @Test func localFormatsOffsets() {
        let t = instant("2026-10-29T10:32:11.123Z")
        #expect(Timestamp.local(t, in: zone("Asia/Kolkata")) == "2026-10-29T16:02:11+05:30")
        #expect(Timestamp.local(t, in: zone("America/Sao_Paulo")) == "2026-10-29T07:32:11-03:00")
        #expect(Timestamp.local(t, in: TimeZone(secondsFromGMT: 0)!) == "2026-10-29T10:32:11+00:00")
        #expect(Timestamp.local(t, in: zone("America/New_York")) == "2026-10-29T06:32:11-04:00")
    }

    @Test func parseAcceptsRFC3339() {
        #expect(Timestamp.parse("2026-10-29T10:32:11Z") == Date(timeIntervalSince1970: 1_793_269_931))
        #expect(Timestamp.parse("2026-10-29T16:02:11+05:30") == Timestamp.parse("2026-10-29T10:32:11Z"))
        #expect(Timestamp.parse("2026-10-29T07:32:11-03:00") == Timestamp.parse("2026-10-29T10:32:11Z"))
        #expect(Timestamp.parse("2026-10-29t10:32:11z") == Timestamp.parse("2026-10-29T10:32:11Z"))
        #expect(Timestamp.parse("2026-10-29T10:32:11.5Z").map(Timestamp.utc) == "2026-10-29T10:32:11.500Z")
        #expect(Timestamp.parse("2026-10-29T10:32:11.123456789Z").map(Timestamp.utc) == "2026-10-29T10:32:11.123Z")
        #expect(Timestamp.parse("2026-10-29T10:32:11.12Z").map(Timestamp.utc) == "2026-10-29T10:32:11.120Z")
        #expect(Timestamp.parse("2028-02-29T23:59:59Z") != nil)
    }

    @Test func parseRejectsMalformed() {
        for bad in [
            "2026-10-29T16:02:11", "2026-10-29 16:02:11Z", "2026-10-29T24:00:00Z", "2026-10-29T10:60:00Z",
            "2026-10-29T10:00:60Z", "2026-02-29T10:00:00Z", "2026-13-29T10:00:00Z", "2026-10-29T10:00:00.Z",
            "2026-10-29T10:00:00.1234567890Z", "2026-10-29T10:00:00+0530", "2026-10-29T10:00:00+05",
            "2026-10-29T10:00:00+24:00", "2026-10-29T10:00:00+05:60", "2026-10-29", "", "2026-10-29T10:00Z",
            " 2026-10-29T10:00:00Z", "2026-10-29T10:00:00Z ", "2026-10-29T10:00:00ZZ", "2026-10-29T1:00:00Z",
        ] {
            #expect(Timestamp.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func roundTrips() {
        for text in ["2026-10-29T10:32:11.123Z", "1999-12-31T23:59:59.999Z", "2026-03-08T07:00:00.000Z"] {
            #expect(Timestamp.parse(text).map(Timestamp.utc) == text)
        }
        let t = instant("2026-10-29T10:32:11.000Z")
        for id in ["Asia/Kolkata", "America/Sao_Paulo", "UTC"] {
            #expect(Timestamp.parse(Timestamp.local(t, in: zone(id))) == t)
        }
    }

    @Test func clockTimeAndInstant() {
        let kolkata = zone("Asia/Kolkata")
        #expect(Timestamp.clockTime(instant("2026-10-29T10:32:11Z"), in: kolkata) == "16:02")
        #expect(Timestamp.clockTime(instant("2026-10-29T18:30:00Z"), in: kolkata) == "00:00")
        let at = Timestamp.instant(clockTime: "10:30", on: date("2026-10-29"), in: kolkata)
        #expect(at.map(Timestamp.utc) == "2026-10-29T05:00:00.000Z")
        #expect(
            Timestamp.instant(clockTime: "00:00", on: date("2026-10-29"), in: kolkata).map(Timestamp.utc)
                == "2026-10-28T18:30:00.000Z")
        for bad in ["25:00", "24:00", "10:60", "9:30", "10:5", "1030", "", "10:30:00", "ab:cd"] {
            #expect(Timestamp.instant(clockTime: bad, on: date("2026-10-29"), in: kolkata) == nil, "\(bad)")
        }
    }

    @Test func instantInGapMovesForward() {
        let ny = zone("America/New_York")
        let t = Timestamp.instant(clockTime: "02:30", on: date("2026-03-08"), in: ny)
        #expect(t.map(Timestamp.utc) == "2026-03-08T07:00:00.000Z")
    }
}
