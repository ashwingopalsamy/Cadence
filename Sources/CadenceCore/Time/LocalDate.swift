import Foundation

/// A calendar date with no zone, "YYYY-MM-DD" (proleptic Gregorian, years 1000...9999).
public struct LocalDate: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1000...9999).contains(year), (1...12).contains(month),
            day >= 1, day <= LocalDate.daysIn(month: month, year: year)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Strict "YYYY-MM-DD": ASCII digits only, nothing around it.
    public init?(_ string: String) {
        let b = Array(string.utf8)
        guard b.count == 10, b[4] == 0x2D, b[7] == 0x2D,
            let y = LocalDate.digits(b[0..<4]), let m = LocalDate.digits(b[5..<7]),
            let d = LocalDate.digits(b[8..<10])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String {
        LocalDate.pad(year, 4) + "-" + LocalDate.pad(month, 2) + "-" + LocalDate.pad(day, 2)
    }

    public static func < (a: LocalDate, b: LocalDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public func adding(days: Int) -> LocalDate {
        LocalDate.fromEpochDays(epochDays + days)
    }

    public func days(until other: LocalDate) -> Int {
        other.epochDays - epochDays
    }

    public var weekday: Weekday {
        // 1970-01-01 was a Thursday (index 3 with Monday = 0).
        let index = LocalDate.floorMod(epochDays + 3, 7)
        return Weekday.allCases[index]
    }

    /// Every date from `from` through `to`, inclusive. Empty when `to` is before `from`.
    public static func range(_ from: LocalDate, through to: LocalDate) -> [LocalDate] {
        let n = from.days(until: to)
        guard n >= 0 else { return [] }
        return (0...n).map { from.adding(days: $0) }
    }

    // MARK: Internals

    /// Days since 1970-01-01.
    var epochDays: Int {
        let y = month <= 2 ? year - 1 : year
        let era = LocalDate.floorDiv(y, 400)
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Inverse of `epochDays`. Clamps to the supported year range instead of trapping.
    static func fromEpochDays(_ days: Int) -> LocalDate {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        if y < 1000 { return LocalDate(year: 1000, month: 1, day: 1) ?? LocalDate(unchecked: 1000, 1, 1) }
        if y > 9999 { return LocalDate(year: 9999, month: 12, day: 31) ?? LocalDate(unchecked: 9999, 12, 31) }
        return LocalDate(year: y, month: m, day: d) ?? LocalDate(unchecked: y, m, d)
    }

    private init(unchecked y: Int, _ m: Int, _ d: Int) {
        year = y
        month = m
        day = d
    }

    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func floorMod(_ a: Int, _ b: Int) -> Int { a - floorDiv(a, b) * b }

    /// Value of a slice of ASCII digits; nil if any byte is not 0-9.
    static func digits(_ bytes: ArraySlice<UInt8>) -> Int? {
        var v = 0
        for c in bytes {
            guard c >= 0x30, c <= 0x39 else { return nil }
            v = v * 10 + Int(c - 0x30)
        }
        return v
    }

    static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}
