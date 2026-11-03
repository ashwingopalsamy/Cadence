import Foundation

/// The SessionStart context line (docs/SPEC.md section 9.3): today's plan, read from the store read-only.
/// This is the only hook code that opens SQLite, and only after the spool line is already written.
public enum HookPlan {
    public static func contextLine(roots: FileRoots, clock: any Clock) -> String? {
        guard let (config, _) = try? ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier),
            config.claudeCode.injectPlanAtSessionStart,
            let zone = TimeZone(identifier: config.profile.timezone),
            FileManager.default.fileExists(atPath: roots.database.path),
            let store = try? SQLiteStore(
                path: roots.database.path, clock: clock, ids: ULIDGenerator(clock: clock, random: SystemRandomSource()),
                readOnly: true, busyTimeoutMilliseconds: 100)
        else { return nil }
        let day = config.dayBoundary.day(of: clock.now(), in: zone)
        guard
            let rows = try? store.db.query(
                "SELECT title, status FROM plan_tasks WHERE day = ? ORDER BY position, created_seq",
                [.text(day.description)])
        else { return nil }
        let tasks = rows.filter { !["dropped", "moved"].contains($0.text("status") ?? "") }
        guard !tasks.isEmpty else { return nil }
        let done = tasks.filter { $0.text("status") == "done" }.count
        let open = tasks.filter { $0.text("status") == "open" }.compactMap { $0.text("title") }
            .compactMap { HookSpool.clean($0, limit: 80) }
        var line = "Cadence plan for \(label(day)), \(done) of \(tasks.count) done"
        if !open.isEmpty { line += ": " + open.prefix(3).joined(separator: "; ") + (open.count > 3 ? "; …" : "") }
        return line
    }

    static func label(_ day: LocalDate) -> String {
        let weekdays: [Weekday: String] = [
            .mon: "Mon", .tue: "Tue", .wed: "Wed", .thu: "Thu", .fri: "Fri", .sat: "Sat", .sun: "Sun",
        ]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(weekdays[day.weekday] ?? "") \(day.day) \(months[day.month - 1])"
    }
}
