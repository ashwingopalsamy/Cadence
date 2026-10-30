import Foundation

/// The first line of an `envelope/1` (docs/SPEC.md section 10.1).
public struct EnvelopeHeader: Sendable, Equatable {
    public var collector: String
    public var run: String
    public var generatedAt: String
    public var since: String
    public var until: String
}

/// An `item` record, checked and resolved to a day, not yet written.
struct ItemRecord: Sendable, Equatable {
    var sourceRef: String
    var kind: EntryKind
    var title: String
    var day: LocalDate
    var occurredAt: Date?
    var ticket: Ticket?
    var links: [Link]
    var tags: [String]
    var attrs: [String: JSONValue]
    var durationS: Int64?
    var quantity: Int64
}

struct UsageRecord: Sendable, Equatable {
    var sourceRef: String
    var day: LocalDate
    var tool: String
    var model: String
    var sessions: Int64?
    var requests: Int64?
    var tokens: TokenCounts
    var costMicros: Int64?
    /// The cost was computed from a price table, not reported by the source.
    var estimated: Bool
}

struct PresenceRecord: Sendable, Equatable {
    var sourceRef: String
    var start: Date
    var end: Date
}

struct LeaveRecord: Sendable, Equatable {
    var sourceRef: String
    var day: LocalDate
    var kind: DayKind
    var label: String?
}

enum EnvelopeRecord: Sendable, Equatable {
    case item(ItemRecord)
    case usage(UsageRecord)
    case presence(PresenceRecord)
    case leave(LeaveRecord)
}

/// One record line: its 1-based line number and either the record or why it was skipped.
struct EnvelopeLine: Sendable {
    var number: Int
    var record: Result<EnvelopeRecord, CadenceError>
    var warnings: [String]
}

/// What the reader needs besides the bytes: the clock, the profile zone and the rules from config.
struct EnvelopeContext {
    var now: Date
    var zone: TimeZone
    var boundary: DayBoundary
    var classifier: TicketClassifier
    /// Lowercased hosts whose `http` links are kept.
    var httpHosts: Set<String>
}

/// Reads an `envelope/1`. Structural problems with the whole envelope throw; a bad record becomes a
/// skipped line with its reason, so one bad line never costs the rest.
struct EnvelopeReader {
    static let format = "envelope/1"
    static let maxBytes = 10 * 1024 * 1024
    static let maxRecords = 20_000
    static let maxTitle = 200
    static let maxAttrsBytes = 2048
    static let maxLinks = 5
    static let maxTags = 10
    static let maxSourceRef = 200
    static let maxLabel = 100
    /// How far ahead of the clock a time may be before it counts as the future (clock drift between machines).
    static let skew: TimeInterval = 300
    /// How far ahead a leave day may be declared.
    static let leaveHorizonDays = 400

    let context: EnvelopeContext

    /// Splits the envelope into its header and record lines. Blank lines are ignored and a trailing CR is dropped.
    static func split(_ bytes: [UInt8]) throws(CadenceError) -> (header: (Int, ArraySlice<UInt8>), records: [(Int, ArraySlice<UInt8>)]) {
        guard bytes.count <= maxBytes else { throw .validation("the envelope is larger than 10 MB") }
        var lines: [(Int, ArraySlice<UInt8>)] = []
        var start = 0
        var number = 0
        func take(_ end: Int) {
            number += 1
            var line = bytes[start..<end]
            if line.last == 0x0D { line = line.dropLast() }
            if line.contains(where: { $0 != 0x20 && $0 != 0x09 }) { lines.append((number, line)) }
        }
        for (i, byte) in bytes.enumerated() where byte == 0x0A {
            take(i)
            start = i + 1
        }
        if start < bytes.count { take(bytes.count) }
        guard let header = lines.first else { throw .validation("the envelope is empty") }
        let records = Array(lines.dropFirst())
        guard records.count <= maxRecords else { throw .validation("the envelope has more than 20,000 records") }
        return (header, records)
    }

    static func header(_ line: ArraySlice<UInt8>, collector: String) throws(CadenceError) -> EnvelopeHeader {
        let value: JSONValue
        do {
            value = try JSONParser.parse(bytes: Array(line))
        } catch {
            throw .validation("header: \(describe(error))")
        }
        let r = try RecordReader(value, owner: "header", required: ["cadence", "collector", "run", "generated_at", "window"])
        guard try r.string("cadence") == format else { throw r.fail("cadence", "must be '\(format)'") }
        let named = try r.string("collector")
        guard named == collector else { throw r.fail("collector", "names '\(named)', but this is collector '\(collector)'") }
        let run = try r.string("run")
        guard (1...64).contains(run.count), run.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F })
        else { throw r.fail("run", "must be 1 to 64 printable ASCII characters") }
        let generated = try r.string("generated_at")
        guard Timestamp.parse(generated) != nil else { throw r.fail("generated_at", "must be an RFC 3339 time with an offset") }
        let w = try RecordReader(r.raw("window"), owner: "header.window", required: ["since", "until"])
        var edges: [String] = []
        for key in ["since", "until"] {
            let edge = try w.string(key)
            guard LocalDate(edge) != nil || Timestamp.parse(edge) != nil else { throw w.fail(key, "must be a day or an RFC 3339 time") }
            edges.append(edge)
        }
        return EnvelopeHeader(collector: named, run: run, generatedAt: generated, since: edges[0], until: edges[1])
    }

    func line(_ number: Int, _ bytes: ArraySlice<UInt8>) -> EnvelopeLine {
        var warnings: [String] = []
        do throws(CadenceError) {
            let value: JSONValue
            do {
                value = try JSONParser.parse(bytes: Array(bytes))
            } catch {
                throw .validation(Self.describe(error))
            }
            guard let type = value.objectValue?["type"]?.stringValue else {
                throw .validation("type: is required and must be a string")
            }
            let record: EnvelopeRecord
            switch type {
            case "item": record = .item(try item(value, warnings: &warnings))
            case "genai.usage": record = .usage(try usage(value))
            case "presence.span": record = .presence(try presence(value))
            case "leave": record = .leave(try leave(value))
            default: throw .validation("type: '\(Self.printable(type))' is not a record type")
            }
            return EnvelopeLine(number: number, record: .success(record), warnings: warnings)
        } catch {
            return EnvelopeLine(number: number, record: .failure(error), warnings: warnings)
        }
    }

    // MARK: - Records

    private func item(_ value: JSONValue, warnings: inout [String]) throws(CadenceError) -> ItemRecord {
        let r = try RecordReader(
            value, owner: "item", required: ["type", "source_ref", "kind", "title"],
            optional: ["occurred_at", "day", "ticket", "links", "attrs", "duration_s", "quantity", "tags"])
        let sourceRef = try sourceRef(r)
        let kindText = try r.string("kind")
        guard let kind = EntryKind(rawValue: kindText) else { throw r.fail("kind", "'\(Self.printable(kindText))' is not an entry kind") }

        var title = Journal.clean(try r.string("title"), limit: Self.maxTitle)
        guard !title.isEmpty else { throw r.fail("title", "is empty") }

        let occurred = try r.optionalString("occurred_at").map { text throws(CadenceError) in try time(r, "occurred_at", text) }
        let day: LocalDate
        if let text = try r.optionalString("day") {
            guard let stated = LocalDate(text) else { throw r.fail("day", "must be a date as YYYY-MM-DD") }
            day = stated
            if let occurred, context.boundary.day(of: occurred, in: context.zone) != stated {
                throw r.fail("occurred_at", "is not on \(stated)")
            }
        } else if let occurred {
            day = context.boundary.day(of: occurred, in: context.zone)
        } else {
            throw r.fail("occurred_at", "or day is required")
        }
        guard day <= today else { throw r.fail("day", "\(day) is in the future") }

        // A stated ticket must hold a key; otherwise the title is searched, and a key that opens the title is
        // dropped from it because the entry carries it as its ticket.
        var ticket: Ticket?
        if let text = try r.optionalString("ticket") {
            guard let match = context.classifier.firstTicket(in: text) else { throw r.fail("ticket", "holds no ticket key") }
            ticket = Ticket(key: match.key, class: match.selfInitiated ? .selfInitiated : .assigned)
        } else if let match = context.classifier.titleTicket(in: title) {
            ticket = Ticket(key: match.key, class: match.selfInitiated ? .selfInitiated : .assigned)
            if match.range.lowerBound == title.startIndex {
                let rest = Self.trimSeparators(String(title[match.range.upperBound...]))
                if !rest.isEmpty { title = rest }
            }
        }

        var links: [Link] = []
        if let raw = r.fields["links"], !raw.isNull {
            guard let array = raw.arrayValue else { throw r.fail("links", "must be an array") }
            for (index, element) in array.enumerated() {
                let l = try RecordReader(element, owner: "item.links[\(index)]", required: ["url"], optional: ["kind"])
                let url = try l.string("url")
                guard isKeptURL(url) else {
                    warnings.append("links[\(index)]: only https links (or http on a host in config.hosts) are kept; dropped")
                    continue
                }
                let link: Link
                if let kindText = try l.optionalString("kind") {
                    guard let linkKind = LinkKind(rawValue: kindText) else { throw l.fail("kind", "must be pr, ticket, doc or other") }
                    link = Link(kind: linkKind, url: url)
                } else {
                    link = Link.inferred(url: url)
                }
                if links.contains(link) { continue }
                guard links.count < Self.maxLinks else {
                    warnings.append("links[\(index)]: at most \(Self.maxLinks) links are kept; dropped")
                    continue
                }
                links.append(link)
            }
        }

        var tags: [String] = []
        for (index, tag) in try r.strings("tags").enumerated() {
            guard (1...40).contains(tag.count), !tag.contains(where: { $0.isWhitespace }),
                !tag.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { throw r.fail("tags[\(index)]", "must be 1 to 40 characters with no spaces") }
            if !tags.contains(tag) { tags.append(tag) }
        }
        guard tags.count <= Self.maxTags else { throw r.fail("tags", "at most \(Self.maxTags)") }

        var attrs: [String: JSONValue] = [:]
        if let raw = r.fields["attrs"], !raw.isNull {
            guard let object = raw.objectValue else { throw r.fail("attrs", "must be an object") }
            for key in object.keys.sorted() {
                guard (1...64).contains(key.count), !key.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
                else { throw r.fail("attrs", "keys must be 1 to 64 characters") }
                switch object[key]! {
                case .string(let s):
                    guard !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                        throw r.fail("attrs.\(key)", "must not hold control characters")
                    }
                case .int(let i):
                    guard i >= 0 else { throw r.fail("attrs.\(key)", "must not be negative") }
                case .bool: break
                default: throw r.fail("attrs.\(key)", "must be a string, integer or boolean")
                }
            }
            attrs = object
            let size = (try? CanonicalJSON.bytes(.object(attrs)).count) ?? Int.max
            guard size < Self.maxAttrsBytes else { throw r.fail("attrs", "must stay under 2 KB") }
        }

        let durationS = try r.optionalInt("duration_s")
        if let d = durationS, d > 86_400 { throw r.fail("duration_s", "must be at most 86400") }
        let quantity = try r.optionalInt("quantity") ?? 1
        guard (1...1000).contains(quantity) else { throw r.fail("quantity", "must be between 1 and 1000") }

        return ItemRecord(
            sourceRef: sourceRef, kind: kind, title: title, day: day, occurredAt: occurred, ticket: ticket, links: links,
            tags: tags, attrs: attrs, durationS: durationS, quantity: quantity)
    }

    private func usage(_ value: JSONValue) throws(CadenceError) -> UsageRecord {
        let r = try RecordReader(
            value, owner: "genai.usage", required: ["type", "source_ref", "day", "tool"],
            optional: ["model", "sessions", "requests", "tokens", "cost_micros", "estimated"])
        let sourceRef = try sourceRef(r)
        let day = try pastDay(r)
        let tool = try r.string("tool")
        guard Self.isName(tool) else { throw r.fail("tool", "must be 1 to 100 letters, digits or . _ - / @ +") }
        let model = try r.optionalString("model") ?? "*"
        guard model == "*" || Self.isName(model) else { throw r.fail("model", "must be 1 to 100 letters, digits or . _ - / @ +") }
        var tokens = TokenCounts()
        if let raw = r.fields["tokens"], !raw.isNull {
            let t = try RecordReader(raw, owner: "genai.usage.tokens", required: [], optional: ["in", "out", "cache_read", "cache_write"])
            tokens = TokenCounts(
                input: try t.optionalInt("in"), output: try t.optionalInt("out"), cacheRead: try t.optionalInt("cache_read"),
                cacheWrite: try t.optionalInt("cache_write"))
        }
        let estimated: Bool
        switch r.raw("estimated") {
        case .null: estimated = false
        case .bool(let b): estimated = b
        default: throw r.fail("estimated", "must be a boolean")
        }
        return UsageRecord(
            sourceRef: sourceRef, day: day, tool: tool, model: model, sessions: try r.optionalInt("sessions"),
            requests: try r.optionalInt("requests"), tokens: tokens, costMicros: try r.optionalInt("cost_micros"),
            estimated: estimated)
    }

    private func presence(_ value: JSONValue) throws(CadenceError) -> PresenceRecord {
        let r = try RecordReader(value, owner: "presence.span", required: ["type", "source_ref", "start", "end"])
        let sourceRef = try sourceRef(r)
        let start = try time(r, "start", try r.string("start"))
        let end = try time(r, "end", try r.string("end"))
        guard start <= end else { throw r.fail("end", "must not be before start") }
        guard end.timeIntervalSince(start) <= 86_400 else { throw r.fail("end", "a span is at most 24 hours") }
        return PresenceRecord(sourceRef: sourceRef, start: start, end: end)
    }

    private func leave(_ value: JSONValue) throws(CadenceError) -> LeaveRecord {
        let r = try RecordReader(value, owner: "leave", required: ["type", "source_ref", "day", "kind"], optional: ["label"])
        let sourceRef = try sourceRef(r)
        let text = try r.string("day")
        guard let day = LocalDate(text) else { throw r.fail("day", "must be a date as YYYY-MM-DD") }
        guard day <= today.adding(days: Self.leaveHorizonDays) else { throw r.fail("day", "is more than \(Self.leaveHorizonDays) days ahead") }
        let kindText = try r.string("kind")
        guard let kind = DayKind(rawValue: kindText), [.holiday, .leavePlanned, .leaveUnplanned].contains(kind) else {
            throw r.fail("kind", "must be holiday, leave_planned or leave_unplanned")
        }
        let label = try r.optionalString("label").map { Journal.clean($0, limit: Self.maxLabel) }.flatMap { $0.isEmpty ? nil : $0 }
        return LeaveRecord(sourceRef: sourceRef, day: day, kind: kind, label: label)
    }

    // MARK: - Fields

    private var today: LocalDate { context.boundary.day(of: context.now, in: context.zone) }

    private func sourceRef(_ r: RecordReader) throws(CadenceError) -> String {
        let ref = try r.string("source_ref")
        guard (1...Self.maxSourceRef).contains(ref.count),
            !ref.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == " " })
        else { throw r.fail("source_ref", "must be 1 to \(Self.maxSourceRef) characters with no spaces") }
        return ref
    }

    private func pastDay(_ r: RecordReader) throws(CadenceError) -> LocalDate {
        let text = try r.string("day")
        guard let day = LocalDate(text) else { throw r.fail("day", "must be a date as YYYY-MM-DD") }
        guard day <= today else { throw r.fail("day", "\(day) is in the future") }
        return day
    }

    private func time(_ r: RecordReader, _ key: String, _ text: String) throws(CadenceError) -> Date {
        guard let date = Timestamp.parse(text) else { throw r.fail(key, "must be an RFC 3339 time with an offset") }
        guard date.timeIntervalSince(context.now) <= Self.skew else { throw r.fail(key, "is in the future") }
        return date
    }

    /// `https`, or `http` on a host listed in `config.hosts`; a host is required and spaces or control characters are not allowed.
    private func isKeptURL(_ url: String) -> Bool {
        guard url.count <= 2048,
            !url.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.isWhitespace }),
            let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
            let host = parts.host?.lowercased(), !host.isEmpty
        else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && context.httpHosts.contains(host)
    }

    private static func isName(_ text: String) -> Bool {
        (1...100).contains(text.count)
            && text.unicodeScalars.allSatisfy {
                ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || "._-/@+".unicodeScalars.contains($0)
            }
    }

    private static func trimSeparators(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " :-|]").union(.whitespaces))
    }

    /// Text from the envelope, safe to quote in a message: control characters out, at most 40 characters.
    static func printable(_ text: String) -> String { Journal.clean(text, limit: 40) }

    static func describe(_ error: JSONParser.Failure) -> String {
        switch error {
        case .invalidUTF8: "is not valid UTF-8"
        case .unexpectedEnd: "is not complete JSON"
        case .unexpectedByte(_, let offset): "is not valid JSON (unexpected character at offset \(offset))"
        case .floatNotAllowed: "numbers must be integers"
        case .integerOutOfRange: "a number is too large"
        case .invalidEscape: "has an invalid escape"
        case .unpairedSurrogate: "has an unpaired surrogate"
        case .controlCharacterInString: "has a raw control character in a string"
        case .duplicateKey(let key): "has the key '\(printable(key))' twice"
        case .trailingContent: "holds more than one JSON value"
        case .tooDeep: "nests too deeply"
        }
    }
}

/// Reads one envelope object: the required keys must be present, and any key outside required and optional is refused.
struct RecordReader {
    let owner: String
    let fields: [String: JSONValue]

    init(_ json: JSONValue, owner: String, required: [String], optional: [String] = []) throws(CadenceError) {
        guard case .object(let object) = json else { throw .validation("\(owner): must be an object") }
        for key in required where object[key] == nil || object[key]?.isNull == true {
            throw .validation("\(owner).\(key): is required")
        }
        let allowed = Set(required + optional)
        for key in object.keys.sorted() where !allowed.contains(key) {
            throw .validation("\(owner).\(EnvelopeReader.printable(key)): unknown field")
        }
        self.owner = owner
        self.fields = object
    }

    func fail(_ key: String, _ what: String) -> CadenceError { .validation("\(owner).\(key): \(what)") }

    func raw(_ key: String) -> JSONValue { fields[key] ?? .null }

    func string(_ key: String) throws(CadenceError) -> String {
        guard let s = raw(key).stringValue else { throw fail(key, "must be a string") }
        return s
    }

    func optionalString(_ key: String) throws(CadenceError) -> String? {
        raw(key).isNull ? nil : try string(key)
    }

    func optionalInt(_ key: String) throws(CadenceError) -> Int64? {
        if raw(key).isNull { return nil }
        guard let i = raw(key).intValue else { throw fail(key, "must be an integer") }
        guard i >= 0 else { throw fail(key, "must not be negative") }
        return i
    }

    func strings(_ key: String) throws(CadenceError) -> [String] {
        if raw(key).isNull { return [] }
        guard let array = raw(key).arrayValue else { throw fail(key, "must be an array of strings") }
        var out: [String] = []
        for element in array {
            guard let s = element.stringValue else { throw fail(key, "must be an array of strings") }
            out.append(s)
        }
        return out
    }
}
