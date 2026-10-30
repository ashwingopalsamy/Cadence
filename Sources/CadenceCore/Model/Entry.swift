public struct Ticket: Sendable, Equatable, Hashable, JSONRepresentable {
    public var key: String
    public var `class`: TicketClass

    public init(key: String, class ticketClass: TicketClass) {
        self.key = key
        self.class = ticketClass
    }

    public var json: JSONValue { ["key": .string(key), "class": .string(self.class.rawValue)] }

    public init(json: JSONValue) throws(CadenceError) {
        let f = try JSONFields(json, owner: "ticket")
        key = try f.string("key")
        self.class = try f.enumValue("class")
    }
}

public struct Link: Sendable, Equatable, Hashable, JSONRepresentable {
    public var kind: LinkKind
    public var url: String

    public init(kind: LinkKind, url: String) {
        self.kind = kind
        self.url = url
    }

    public var json: JSONValue { ["kind": .string(kind.rawValue), "url": .string(url)] }

    public init(json: JSONValue) throws(CadenceError) {
        let f = try JSONFields(json, owner: "link")
        kind = try f.enumValue("kind")
        url = try f.string("url")
    }
}

/// The universal log record (docs/SPEC.md sections 7.1 and 7.2).
public struct Entry: Sendable, Equatable, JSONRepresentable {
    public var id: String
    public var day: String
    public var kind: EntryKind
    public var family: Family
    public var title: String
    public var occurredAt: String?
    public var durationS: Int64?
    public var quantity: Int64
    public var ticket: Ticket?
    public var links: [Link]
    public var tags: [String]
    public var attrs: [String: JSONValue]
    public var origin: Origin
    public var source: String?
    public var sourceRef: String?
    public var status: EntryStatus
    public var backfilled: Bool
    public var afterSeal: Bool
    public var export: ExportPolicy

    public init(
        id: String, day: String, kind: EntryKind, family: Family, title: String,
        occurredAt: String? = nil, durationS: Int64? = nil, quantity: Int64 = 1,
        ticket: Ticket? = nil, links: [Link] = [], tags: [String] = [],
        attrs: [String: JSONValue] = [:], origin: Origin, source: String? = nil,
        sourceRef: String? = nil, status: EntryStatus = .accepted, backfilled: Bool = false,
        afterSeal: Bool = false, export: ExportPolicy = .include
    ) {
        self.id = id
        self.day = day
        self.kind = kind
        self.family = family
        self.title = title
        self.occurredAt = occurredAt
        self.durationS = durationS
        self.quantity = quantity
        self.ticket = ticket
        self.links = links
        self.tags = tags
        self.attrs = attrs
        self.origin = origin
        self.source = source
        self.sourceRef = sourceRef
        self.status = status
        self.backfilled = backfilled
        self.afterSeal = afterSeal
        self.export = export
    }

    public var json: JSONValue {
        [
            "id": .string(id),
            "day": .string(day),
            "kind": .string(kind.rawValue),
            "family": .string(family.rawValue),
            "title": .string(title),
            "occurred_at": occurredAt.jsonValue,
            "duration_s": durationS.jsonValue,
            "quantity": .int(quantity),
            "ticket": ticket?.json ?? .null,
            "links": .array(links.map(\.json)),
            "tags": .array(tags.map { .string($0) }),
            "attrs": .object(attrs),
            "origin": .string(origin.rawValue),
            "source": source.jsonValue,
            "source_ref": sourceRef.jsonValue,
            "status": .string(status.rawValue),
            "backfilled": .bool(backfilled),
            "after_seal": .bool(afterSeal),
            "export": .string(export.rawValue),
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let f = try JSONFields(json, owner: "entry")
        id = try f.string("id")
        day = try f.string("day")
        kind = try f.enumValue("kind")
        family = try f.enumValue("family")
        title = try f.string("title")
        occurredAt = try f.optionalString("occurred_at")
        durationS = try f.optionalInt("duration_s")
        quantity = try f.int("quantity", default: 1)
        if let t = f.value("ticket") { ticket = try Ticket(json: t) } else { ticket = nil }
        var parsedLinks: [Link] = []
        for item in try f.array("links") { parsedLinks.append(try Link(json: item)) }
        links = parsedLinks
        tags = try f.strings("tags")
        attrs = try f.object("attrs")
        origin = try f.enumValue("origin")
        source = try f.optionalString("source")
        sourceRef = try f.optionalString("source_ref")
        status = try f.enumValue("status", default: EntryStatus.accepted)
        backfilled = try f.bool("backfilled", default: false)
        afterSeal = try f.bool("after_seal", default: false)
        export = try f.enumValue("export", default: ExportPolicy.include)
    }
}
