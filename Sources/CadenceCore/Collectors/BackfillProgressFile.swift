import Foundation

/// A backfill in progress, as a file the collector agent writes and the app reads for "First sync running" (docs/SPEC.md
/// section 5.2): what is being imported, the workdays its finished chunks cover and the workdays in its whole range. It
/// lives in `state/` and goes when the backfill ends. A file not updated for `staleAfter` is a run that died, read as none.
public enum BackfillProgressFile {
    public struct Progress: Sendable, Equatable {
        /// The months imported, such as "October" or "September to October".
        public var label: String
        public var done: Int
        public var total: Int

        public init(label: String, done: Int, total: Int) {
            self.label = label
            self.done = done
            self.total = total
        }
    }

    /// One chunk is a week of one source, so a quarter of an hour without news is a run that is gone.
    public static let staleAfter: TimeInterval = 15 * 60

    public static func url(_ roots: FileRoots) -> URL { roots.state.appendingPathComponent("backfill.json") }

    /// Records progress at `now`, or removes the file when `progress` is nil.
    public static func write(_ progress: Progress?, roots: FileRoots, now: Date) throws(CadenceError) {
        let file = url(roots)
        guard let progress else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let bytes: [UInt8]
        do {
            bytes = try CanonicalJSON.bytes([
                "label": .string(progress.label), "done": .int(Int64(progress.done)), "total": .int(Int64(progress.total)),
                "updated": .string(Timestamp.utc(now)),
            ])
        } catch {
            throw .io("cannot encode the backfill progress")
        }
        try PrivateFile.save(bytes + [0x0A], to: file)
    }

    /// The backfill running at `now`, if one is.
    public static func read(roots: FileRoots, now: Date) -> Progress? {
        guard let data = PrivateFile.readOwned(url(roots)), let object = (try? JSONParser.parse(bytes: data))?.objectValue,
            let label = object["label"]?.stringValue, let done = object["done"]?.intValue,
            let total = object["total"]?.intValue, let text = object["updated"]?.stringValue,
            let updated = Timestamp.parse(text), now.timeIntervalSince(updated) < staleAfter, done < total
        else { return nil }
        return Progress(label: label, done: Int(done), total: Int(total))
    }

    /// The days from `from` through `through` that fall on one of `workdays`.
    public static func workdays(from: LocalDate, through: LocalDate, in workdays: [Weekday]) -> Int {
        var count = 0
        var day = from
        while day <= through {
            if workdays.contains(day.weekday) { count += 1 }
            day = day.adding(days: 1)
        }
        return count
    }

    /// "October" for one month, "September to October" for more.
    public static func label(from: LocalDate, through: LocalDate) -> String {
        let first = monthNames[from.month - 1], last = monthNames[through.month - 1]
        return from.month == through.month && from.year == through.year ? first : "\(first) to \(last)"
    }

    static let monthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
    ]
}
