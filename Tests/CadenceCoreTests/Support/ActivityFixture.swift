import Foundation

@testable import CadenceCore

/// Three October weeks of first and last activity, with a weekend, declared days off, a day in another zone and an
/// extra declared workday mixed in. Everything is synthetic. The ledger began Thu 1 Oct, and the clock reads Mon 26 Oct,
/// after the range Mon 5 to Sun 25 Oct, so every day in it is final.
///
/// Workdays, in the profile zone (Asia/Kolkata) unless a zone is named:
///
///     Mon 5   09:00 to 17:00    Mon 12  10:00 to 18:00    Mon 19  11:00 to 19:00
///     Tue 6   09:00 to 17:30 in America/New_York (18:30 to 03:00 in Kolkata)
///     Tue 13  09:30 to 17:30
///     Wed 7   09:00 to 18:00
///     Thu 8   10:00, and no end
///     Sat 17  12:00 to 14:00, declared a workday
///
/// Days that must never count:
///
///     Wed 14  declared leave, 06:00 to 23:00        Thu 15  declared holiday, 07:00 to 12:00
///     Sat 10  weekend, 05:00 to 23:30               Sun 11  weekend, 04:30 to 22:00
enum ActivityFixture {
    static let kolkata = "Asia/Kolkata"
    static let newYork = "America/New_York"

    static func make() throws -> (journal: Journal, store: SQLiteStore, clock: ManualClock) {
        let clock = ManualClock(Timestamp.parse("2026-10-01T04:00:00Z")!)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let journal = try Journal(
            store: store, config: Config.defaults(timezone: kolkata), clock: clock, ids: CountingIDs())

        try journal.declare(LocalDate("2026-10-14")!, kind: .leavePlanned, label: "Leave", actor: .cli)
        try journal.declare(LocalDate("2026-10-15")!, kind: .holiday, label: "Holiday", actor: .cli)
        try journal.declare(LocalDate("2026-10-17")!, kind: .workday, label: nil, actor: .cli)

        try mark(store, "2026-10-05", first: "09:00", last: "17:00")
        try mark(store, "2026-10-12", first: "10:00", last: "18:00")
        try mark(store, "2026-10-19", first: "11:00", last: "19:00")
        try mark(store, "2026-10-06", first: "09:00", last: "17:30", offset: "-04:00", tz: newYork)
        try mark(store, "2026-10-13", first: "09:30", last: "17:30")
        try mark(store, "2026-10-07", first: "09:00", last: "18:00")
        try mark(store, "2026-10-08", first: "10:00")
        try mark(store, "2026-10-17", first: "12:00", last: "14:00")

        try mark(store, "2026-10-14", first: "06:00", last: "23:00")
        try mark(store, "2026-10-15", first: "07:00", last: "12:00")
        try mark(store, "2026-10-10", first: "05:00", last: "23:30")
        try mark(store, "2026-10-11", first: "04:30", last: "22:00")

        clock.set(Timestamp.parse("2026-10-26T04:00:00Z")!)
        return (journal, store, clock)
    }

    /// A manual day start and end, which set `first_activity` and `last_activity` exactly.
    static func mark(
        _ store: SQLiteStore, _ day: String, first: String? = nil, last: String? = nil, offset: String = "+05:30",
        tz: String = kolkata
    ) throws {
        var drafts: [EventDraft] = []
        if let first {
            let at = "\(day)T\(first):00\(offset)"
            drafts.append(EventPayload.dayStarted(DayMark(day: day, tz: tz, at: at, source: .manual)).draft(actor: .cli))
        }
        if let last {
            let at = "\(day)T\(last):00\(offset)"
            drafts.append(EventPayload.dayEnded(DayMark(day: day, tz: tz, at: at, source: .manual)).draft(actor: .cli))
        }
        try store.append(drafts)
    }
}
