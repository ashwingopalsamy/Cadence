/// A planned task for a day (docs/SPEC.md section 7.1). Plan versus done is computed only from these.
public struct PlanTask: Sendable, Equatable, JSONRepresentable {
    public var id: String
    public var day: String
    public var position: Int64
    public var title: String
    public var ticket: Ticket?
    public var estimateMin: Int64?
    public var origin: PlanOrigin
    public var carriedFrom: String?
    public var status: TaskStatus
    public var reason: String?
    public var reasonNote: String?
    public var linkedEntries: [String]
    public var plannedAt: String
    public var resolvedAt: String?

    public init(
        id: String, day: String, position: Int64, title: String, ticket: Ticket? = nil,
        estimateMin: Int64? = nil, origin: PlanOrigin, carriedFrom: String? = nil,
        status: TaskStatus = .open, reason: String? = nil, reasonNote: String? = nil,
        linkedEntries: [String] = [], plannedAt: String, resolvedAt: String? = nil
    ) {
        self.id = id
        self.day = day
        self.position = position
        self.title = title
        self.ticket = ticket
        self.estimateMin = estimateMin
        self.origin = origin
        self.carriedFrom = carriedFrom
        self.status = status
        self.reason = reason
        self.reasonNote = reasonNote
        self.linkedEntries = linkedEntries
        self.plannedAt = plannedAt
        self.resolvedAt = resolvedAt
    }

    public var json: JSONValue {
        [
            "id": .string(id),
            "day": .string(day),
            "position": .int(position),
            "title": .string(title),
            "ticket": ticket?.json ?? .null,
            "estimate_min": estimateMin.jsonValue,
            "origin": .string(origin.rawValue),
            "carried_from": carriedFrom.jsonValue,
            "status": .string(status.rawValue),
            "reason": reason.jsonValue,
            "reason_note": reasonNote.jsonValue,
            "linked_entries": .array(linkedEntries.map { .string($0) }),
            "planned_at": .string(plannedAt),
            "resolved_at": resolvedAt.jsonValue,
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let f = try JSONFields(json, owner: "plan_task")
        id = try f.string("id")
        day = try f.string("day")
        position = try f.int("position")
        title = try f.string("title")
        if let t = f.value("ticket") { ticket = try Ticket(json: t) } else { ticket = nil }
        estimateMin = try f.optionalInt("estimate_min")
        origin = try f.enumValue("origin")
        carriedFrom = try f.optionalString("carried_from")
        status = try f.enumValue("status", default: TaskStatus.open)
        reason = try f.optionalString("reason")
        reasonNote = try f.optionalString("reason_note")
        linkedEntries = try f.strings("linked_entries")
        plannedAt = try f.string("planned_at")
        resolvedAt = try f.optionalString("resolved_at")
    }
}
