import Foundation

/// RFC 3339 formatting and parsing, plus local clock helpers. Pure arithmetic; no locale, no `Date()`.
public enum Timestamp {
    /// "2026-10-29T10:32:11.123Z": UTC, exactly 3 fractional digits (truncated, not rounded).
    public static func utc(_ date: Date) -> String {
        let ms = epochMilliseconds(date)
        let seconds = LocalDate.floorDiv(ms, 1000)
        let frac = LocalDate.floorMod(ms, 1000)
        return wall(seconds) + "." + LocalDate.pad(frac, 3) + "Z"
    }

    /// "2026-10-29T16:02:11+05:30" in `zone`. Offset is "+00:00" for UTC, never "Z".
    public static func local(_ date: Date, in zone: TimeZone) -> String {
        let offset = zone.secondsFromGMT(for: date)
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        let sign = offset < 0 ? "-" : "+"
        let a = abs(offset)
        let suffix = sign + LocalDate.pad(a / 3600, 2) + ":" + LocalDate.pad((a % 3600) / 60, 2)
        return wall(seconds + offset) + suffix
    }

    /// Strict RFC 3339 with a required offset ("Z"/"z" or +-HH:MM), optional fraction of 1 to 9 digits
    /// (millisecond precision kept, the rest truncated). "T" may be lowercase.
    public static func parse(_ text: String) -> Date? {
        let b = Array(text.utf8)
        guard b.count >= 20 else { return nil }
        guard b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54 || b[10] == 0x74, b[13] == 0x3A, b[16] == 0x3A,
            let y = LocalDate.digits(b[0..<4]), let mo = LocalDate.digits(b[5..<7]),
            let d = LocalDate.digits(b[8..<10]), let h = LocalDate.digits(b[11..<13]),
            let mi = LocalDate.digits(b[14..<16]), let s = LocalDate.digits(b[17..<19]),
            h <= 23, mi <= 59, s <= 59,
            let date = LocalDate(year: y, month: mo, day: d)
        else { return nil }
        var i = 19
        var ms = 0
        if b[i] == 0x2E {
            i += 1
            let start = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            let n = i - start
            guard (1...9).contains(n) else { return nil }
            var scale = 100
            for k in start..<min(i, start + 3) {
                ms += Int(b[k] - 0x30) * scale
                scale /= 10
            }
        }
        guard i < b.count else { return nil }
        var offset = 0
        switch b[i] {
        case 0x5A, 0x7A:
            guard i + 1 == b.count else { return nil }
        case 0x2B, 0x2D:
            guard i + 6 == b.count, b[i + 3] == 0x3A,
                let oh = LocalDate.digits(b[(i + 1)..<(i + 3)]), let om = LocalDate.digits(b[(i + 4)..<(i + 6)]),
                oh <= 23, om <= 59
            else { return nil }
            offset = (oh * 3600 + om * 60) * (b[i] == 0x2D ? -1 : 1)
        default:
            return nil
        }
        let seconds = date.epochDays * 86_400 + h * 3600 + mi * 60 + s - offset
        return Date(timeIntervalSince1970: Double(seconds * 1000 + ms) / 1000)
    }

    /// "HH:MM" local time of an instant.
    public static func clockTime(_ date: Date, in zone: TimeZone) -> String {
        let secs = LocalDate.floorMod(localSeconds(date, in: zone), 86_400)
        return LocalDate.pad(secs / 3600, 2) + ":" + LocalDate.pad((secs % 3600) / 60, 2)
    }

    /// The instant of "HH:MM" on `day` in `zone` (for `--at 10:30`). nil for invalid text.
    public static func instant(clockTime text: String, on day: LocalDate, in zone: TimeZone) -> Date? {
        guard let (h, m) = parseClock(text) else { return nil }
        return resolve(day, hour: h, minute: m, in: zone)
    }

    // MARK: Internals

    /// Strict "HH:MM", 00:00...23:59.
    static func parseClock(_ text: String) -> (Int, Int)? {
        let b = Array(text.utf8)
        guard b.count == 5, b[2] == 0x3A, let h = LocalDate.digits(b[0..<2]), let m = LocalDate.digits(b[3..<5]),
            h <= 23, m <= 59
        else { return nil }
        return (h, m)
    }

    /// Whole milliseconds since the epoch, truncated toward negative infinity. Rounds to the nearest
    /// microsecond first so binary floating-point error cannot turn .123 into .122.
    static func epochMilliseconds(_ date: Date) -> Int {
        let micros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        return LocalDate.floorDiv(Int(micros), 1000)
    }

    /// Seconds since the epoch as a wall clock in `zone` (whole seconds, floored).
    static func localSeconds(_ date: Date, in zone: TimeZone) -> Int {
        Int(date.timeIntervalSince1970.rounded(.down)) + zone.secondsFromGMT(for: date)
    }

    /// "YYYY-MM-DDTHH:MM:SS" for a count of seconds treated as a wall clock.
    static func wall(_ seconds: Int) -> String {
        let date = LocalDate.fromEpochDays(LocalDate.floorDiv(seconds, 86_400))
        let s = LocalDate.floorMod(seconds, 86_400)
        return date.description + "T" + LocalDate.pad(s / 3600, 2) + ":" + LocalDate.pad((s % 3600) / 60, 2)
            + ":" + LocalDate.pad(s % 60, 2)
    }

    /// The instant at which the wall clock in `zone` reads `day` `hour:minute`. If that time occurs twice the
    /// first occurrence wins; if it does not exist the first instant after the gap is returned.
    static func resolve(_ day: LocalDate, hour: Int, minute: Int, in zone: TimeZone) -> Date {
        let wallSeconds = day.epochDays * 86_400 + hour * 3600 + minute * 60
        func offset(at t: Int) -> Int { zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(t))) }
        let before = offset(at: wallSeconds - 86_400)
        let after = offset(at: wallSeconds + 86_400)
        let candidates = Set([before, after]).map { wallSeconds - $0 }.sorted()
        for t in candidates where wallSeconds - offset(at: t) == t {
            return Date(timeIntervalSince1970: Double(t))
        }
        // Gap: the wall time was skipped. Find the first second whose offset is the post-gap offset.
        var lo = wallSeconds - max(before, after)
        var hi = wallSeconds - min(before, after)
        while hi - lo > 1 {
            let mid = lo + (hi - lo) / 2
            if offset(at: mid) == after { hi = mid } else { lo = mid }
        }
        return Date(timeIntervalSince1970: Double(hi))
    }
}
