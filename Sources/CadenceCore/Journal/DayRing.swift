/// The numbers behind a day's ring (docs/SPEC.md section 5.2): the planned tasks by state, and the accepted
/// entries as beads by family. Derived from a `DayView`, never stored.
public struct DayRing: Sendable, Equatable {
    public struct Bead: Sendable, Equatable {
        public var family: Family
        public var count: Int
    }

    /// Tasks that belong to the day: a task carried to another day has left it.
    public var planned: Int
    public var done: Int
    public var slipped: Int
    public var dropped: Int
    public var open: Int
    /// Accepted entries per family, in the fixed bead order. Families with no entry are left out, and so is
    /// presence, which has no bead. Proposed entries have not happened yet and are not counted.
    public var beads: [Bead]
    public var sealed: Bool

    public init(_ view: DayView) {
        let tasks = view.tasks.filter { $0.status != .moved }
        planned = tasks.count
        done = tasks.filter { $0.status == .done }.count
        slipped = tasks.filter { $0.status == .slipped }.count
        dropped = tasks.filter { $0.status == .dropped }.count
        open = tasks.filter { $0.status == .open }.count
        let accepted = view.entries.filter { $0.status == .accepted }
        beads = Family.ringOrder.compactMap { family in
            let count = accepted.filter { $0.family == family }.count
            return count > 0 ? Bead(family: family, count: count) : nil
        }
        sealed = view.day.sealedAt != nil
    }

    /// The ring reads closed when every planned task is resolved and the day is sealed.
    public var closed: Bool { sealed && open == 0 }

    public var json: JSONValue {
        var counts: [String: JSONValue] = [:]
        for bead in beads { counts[bead.family.rawValue] = .int(Int64(bead.count)) }
        return [
            "planned": .int(Int64(planned)), "done": .int(Int64(done)), "slipped": .int(Int64(slipped)),
            "dropped": .int(Int64(dropped)), "open": .int(Int64(open)), "beads": .object(counts),
            "sealed": .bool(sealed), "closed": .bool(closed),
        ]
    }

    /// One line: "Ring: 2 of 4 planned tasks done, 1 slipped, 1 open; delivery 2, review 1; not sealed".
    public var text: String {
        var parts = [planned == 0 ? "no planned tasks" : "\(done) of \(planned) planned tasks done"]
        if slipped > 0 { parts.append("\(slipped) slipped") }
        if dropped > 0 { parts.append("\(dropped) dropped") }
        if open > 0 { parts.append("\(open) open") }
        var line = "Ring: " + parts.joined(separator: ", ")
        if !beads.isEmpty { line += "; " + beads.map { "\($0.family.rawValue) \($0.count)" }.joined(separator: ", ") }
        return line + (closed ? "; closed" : sealed ? "; sealed" : "; not sealed")
    }
}
