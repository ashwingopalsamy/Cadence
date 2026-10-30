import Foundation

/// What a map made of one document: an envelope ready for `Journal.ingest`, and the records it could not map.
public struct MapOutput: Sendable, Equatable {
    public var envelope: [UInt8]
    public var records: Int
    /// One line per record that could not be mapped, such as "record 3: cost_micros: is not a number".
    public var skipped: [String]
}

/// Applies a `map/1` (docs/SPEC.md section 10.5). Days and times are read in the profile zone.
public struct MapEngine: Sendable {
    public let map: MapFile
    let zone: TimeZone
    let boundary: DayBoundary

    public init(map: MapFile, zone: TimeZone, boundary: DayBoundary) {
        self.map = map
        self.zone = zone
        self.boundary = boundary
    }

    /// Maps `bytes` and wraps the records in an envelope for `collector`. A record that cannot be mapped is left
    /// out and listed in `skipped`; a document that cannot be read at all throws.
    public func envelope(
        from bytes: [UInt8], collector: String, window: IngestWindow, run: String, generatedAt: Date
    ) throws(CadenceError) -> MapOutput {
        guard bytes.count <= EnvelopeReader.maxBytes else { throw .validation("map \(map.name): the input is larger than 10 MB") }
        var lines: [[UInt8]] = []
        let header: JSONValue = [
            "cadence": .string(EnvelopeReader.format), "collector": .string(collector), "run": .string(run),
            "generated_at": .string(Timestamp.local(generatedAt, in: zone)),
            "window": ["since": .string(window.since), "until": .string(window.until)],
        ]
        lines.append(try Self.canonical(header))
        var skipped: [String] = []
        let records = try self.records(from: bytes)
        for (label, result) in records {
            switch result {
            case .success(let record): lines.append(try Self.canonical(record))
            case .failure(let error): skipped.append("\(label): \(error.message)")
            }
        }
        guard records.count <= EnvelopeReader.maxRecords else { throw .validation("map \(map.name): more than 20,000 records") }
        return MapOutput(envelope: Array(lines.joined(separator: [0x0A])) + [0x0A], records: records.count, skipped: skipped)
    }

    /// Every selected record, labelled for messages, mapped to an envelope record or the reason it could not be.
    func records(from bytes: [UInt8]) throws(CadenceError) -> [(String, Result<JSONValue, CadenceError>)] {
        switch map.input {
        case .csv:
            return try CSVReader.rows(bytes).map { row in
                let label = "row at line \(row.line)"
                switch row.value {
                case .success(let object): return (label, Result { () throws(CadenceError) in try record(from: object) })
                case .failure(let error): return (label, .failure(error))
                }
            }
        case .json:
            let document: JSONValue
            do {
                document = try JSONParser.parseKeepingNumberText(bytes: bytes)
            } catch {
                throw .validation("map \(map.name): the input \(EnvelopeReader.describe(error))")
            }
            return map.records.select(document).enumerated().map { index, node in
                ("record \(index + 1)", Result { () throws(CadenceError) in try record(from: node) })
            }
        }
    }

    func record(from node: JSONValue) throws(CadenceError) -> JSONValue {
        var flat: [String: JSONValue] = [:]
        for (name, rule) in map.fields {
            var value: JSONValue?
            if let c = rule.const {
                value = c
            } else if let path = rule.path {
                let found = path.select(node)
                guard found.count <= 1 else { throw .validation("\(name): the path selects more than one value") }
                value = found.first.flatMap { $0.isNull || $0 == .string("") ? nil : $0 }
            }
            if value == nil { value = rule.defaultValue }
            guard let raw = value else { continue }
            flat[name] = try convert(raw, field: name, rule: rule)
        }

        var record: [String: JSONValue] = ["type": .string(map.produces)]
        for (name, value) in flat {
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                var inner = record[parts[0]]?.objectValue ?? [:]
                inner[parts[1]] = value
                record[parts[0]] = .object(inner)
            } else {
                record[name] = value
            }
        }

        var ref = map.sourceRef
        for placeholder in MapFile.placeholders(map.sourceRef) {
            let text: String
            switch flat[placeholder] {
            case .string(let s)?: text = s
            case .int(let i)?: text = String(i)
            case .bool(let b)?: text = b ? "true" : "false"
            default: throw .validation("source_ref: {\(placeholder)} has no value")
            }
            ref = ref.replacingOccurrences(of: "{\(placeholder)}", with: text)
        }
        record["source_ref"] = .string(ref)
        return .object(record)
    }

    private func convert(_ raw: JSONValue, field: String, rule: MapFile.Rule) throws(CadenceError) -> JSONValue {
        if MapFile.integers.contains(field) {
            let text: String
            switch raw {
            case .int(let i): text = String(i)
            case .string(let s): text = s
            default: throw .validation("\(field): is not a number")
            }
            let scale = rule.scale ?? 1
            // Without a scale a value must be whole; with one, digits finer than a unit are rounded.
            guard let value = Decimal10.scaled(text, by: scale, exact: rule.scale == nil) else {
                throw .validation("\(field): '\(EnvelopeReader.printable(text))' is not \(rule.scale == nil ? "a whole number" : "a decimal number in range")")
            }
            guard value >= 0 else { throw .validation("\(field): must not be negative") }
            guard value <= JSONValue.maxSafeInteger else { throw .validation("\(field): is too large") }
            return .int(value)
        }
        if MapFile.booleans.contains(field) {
            switch raw {
            case .bool: return raw
            case .string(let s) where s.lowercased() == "true": return .bool(true)
            case .string(let s) where s.lowercased() == "false": return .bool(false)
            default: throw .validation("\(field): is not true or false")
            }
        }
        if field == "day" || MapFile.times.contains(field) {
            return try moment(raw, field: field, format: rule.format)
        }
        switch raw {
        case .string, .bool: return raw
        case .int(let i): return field.hasPrefix("attrs.") ? raw : .string(String(i))
        default: throw .validation("\(field): must be a single value, not a list or an object")
        }
    }

    /// A day as YYYY-MM-DD, or a time as RFC 3339 in the profile zone, from any of the map formats.
    private func moment(_ raw: JSONValue, field: String, format: MapFile.Format?) throws(CadenceError) -> JSONValue {
        let text: String
        switch raw {
        case .string(let s): text = s.trimmingCharacters(in: .whitespaces)
        case .int(let i): text = String(i)
        default: throw .validation("\(field): is not a day or a time")
        }
        let format = format ?? (field == "day" ? .day : .iso8601)
        let instant: Date
        switch format {
        case .day:
            guard let day = LocalDate(text) else { throw .validation("\(field): '\(EnvelopeReader.printable(text))' is not yyyy-MM-dd") }
            return .string(day.description)
        case .iso8601:
            guard let date = Timestamp.parse(text) else {
                throw .validation("\(field): '\(EnvelopeReader.printable(text))' is not an ISO 8601 time with an offset")
            }
            instant = date
        case .epochSeconds, .epochMilliseconds:
            guard let n = Decimal10.scaled(text, by: 1, exact: true), n >= 0, n < 100_000_000_000_000 else {
                throw .validation("\(field): '\(EnvelopeReader.printable(text))' is not an epoch time")
            }
            instant = Date(timeIntervalSince1970: format == .epochSeconds ? Double(n) : Double(n / 1000) + Double(n % 1000) / 1000)
        }
        if field == "day" { return .string(boundary.day(of: instant, in: zone).description) }
        return .string(Timestamp.local(instant, in: zone))
    }

    private static func canonical(_ value: JSONValue) throws(CadenceError) -> [UInt8] {
        do {
            return try CanonicalJSON.bytes(value)
        } catch {
            throw .validation("a mapped value cannot be written as JSON")
        }
    }
}

extension Result where Failure == CadenceError {
    init(_ body: () throws(CadenceError) -> Success) {
        do throws(CadenceError) {
            self = .success(try body())
        } catch {
            self = .failure(error)
        }
    }
}
