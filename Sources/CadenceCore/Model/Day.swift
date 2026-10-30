/// A local day with the time zone in force (docs/SPEC.md section 7.1).
public struct Day: Sendable, Equatable, JSONRepresentable {
    public var date: String
    public var tz: String
    public var kind: DayKind
    public var label: String?
    public var firstActivity: String?
    public var lastActivity: String?
    public var focus: String?
    public var note: String?
    public var onCall: Bool
    public var sealedAt: String?
    public var sealEvent: String?

    public init(
        date: String, tz: String, kind: DayKind = .workday, label: String? = nil,
        firstActivity: String? = nil, lastActivity: String? = nil, focus: String? = nil,
        note: String? = nil, onCall: Bool = false, sealedAt: String? = nil, sealEvent: String? = nil
    ) {
        self.date = date
        self.tz = tz
        self.kind = kind
        self.label = label
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.focus = focus
        self.note = note
        self.onCall = onCall
        self.sealedAt = sealedAt
        self.sealEvent = sealEvent
    }

    public var json: JSONValue {
        [
            "date": .string(date),
            "tz": .string(tz),
            "kind": .string(kind.rawValue),
            "label": label.jsonValue,
            "first_activity": firstActivity.jsonValue,
            "last_activity": lastActivity.jsonValue,
            "focus": focus.jsonValue,
            "note": note.jsonValue,
            "on_call": .bool(onCall),
            "sealed_at": sealedAt.jsonValue,
            "seal_event": sealEvent.jsonValue,
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let f = try JSONFields(json, owner: "day")
        date = try f.string("date")
        tz = try f.string("tz")
        kind = try f.enumValue("kind", default: DayKind.workday)
        label = try f.optionalString("label")
        firstActivity = try f.optionalString("first_activity")
        lastActivity = try f.optionalString("last_activity")
        focus = try f.optionalString("focus")
        note = try f.optionalString("note")
        onCall = try f.bool("on_call", default: false)
        sealedAt = try f.optionalString("sealed_at")
        sealEvent = try f.optionalString("seal_event")
    }
}
