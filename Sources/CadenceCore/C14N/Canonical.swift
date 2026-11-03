/// cadence-c14n/1: the canonical JSON every hash in Cadence is computed over
/// (docs/SPEC.md sections 7.3 and 12.1). A strict subset of RFC 8785 that is byte-identical to
/// Python's `json.dumps(x, sort_keys=True, separators=(",", ":"), ensure_ascii=False)` for every
/// value it accepts.
///
/// - Object keys are ASCII and sorted by byte value. Non-ASCII keys are rejected.
/// - No whitespace.
/// - `"` and `\` are escaped, as are `\b \f \n \r \t`; other characters below U+0020 become
///   lowercase `\u00xx`; everything else is raw UTF-8, `/` and U+007F included.
/// - Integers only, within ±(2^53 - 1). There is no floating point anywhere.
/// - At most `JSONParser.maxDepth` nested containers.
public enum CanonicalJSON {
    public enum Failure: Error, Equatable, Sendable {
        case nonASCIIKey(String)
        case integerOutOfRange(Int64)
        case tooDeep
    }

    /// The canonical UTF-8 bytes of `value`.
    public static func bytes(_ value: JSONValue) throws(Failure) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        try write(value, into: &out, depth: 0)
        return out
    }

    /// The canonical form as a String (always valid UTF-8).
    public static func string(_ value: JSONValue) throws(Failure) -> String {
        String(decoding: try bytes(value), as: UTF8.self)
    }

    private static func write(_ value: JSONValue, into out: inout [UInt8], depth: Int) throws(Failure) {
        switch value {
        case .null:
            out.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])  // null
        case .bool(let b):
            out.append(contentsOf: b ? [0x74, 0x72, 0x75, 0x65] : [0x66, 0x61, 0x6C, 0x73, 0x65])
        case .int(let i):
            guard i >= -JSONValue.maxSafeInteger, i <= JSONValue.maxSafeInteger else {
                throw .integerOutOfRange(i)
            }
            out.append(contentsOf: String(i).utf8)
        case .string(let s):
            writeString(s, into: &out)
        case .array(let items):
            guard depth < JSONParser.maxDepth else { throw .tooDeep }
            out.append(0x5B)  // [
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(0x2C) }
                try write(item, into: &out, depth: depth + 1)
            }
            out.append(0x5D)  // ]
        case .object(let object):
            guard depth < JSONParser.maxDepth else { throw .tooDeep }
            var keyed: [(key: [UInt8], value: JSONValue)] = []
            keyed.reserveCapacity(object.count)
            for (key, item) in object {
                let utf8 = Array(key.utf8)
                guard utf8.allSatisfy({ $0 < 0x80 }) else { throw .nonASCIIKey(key) }
                keyed.append((utf8, item))
            }
            keyed.sort { $0.key.lexicographicallyPrecedes($1.key) }
            out.append(0x7B)  // {
            for (index, pair) in keyed.enumerated() {
                if index > 0 { out.append(0x2C) }
                writeString(bytes: pair.key, into: &out)
                out.append(0x3A)  // :
                try write(pair.value, into: &out, depth: depth + 1)
            }
            out.append(0x7D)  // }
        }
    }

    private static func writeString(_ s: String, into out: inout [UInt8]) {
        writeString(bytes: Array(s.utf8), into: &out)
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    // Escaping works byte by byte: every byte that needs escaping is ASCII, and UTF-8
    // continuation and lead bytes are all >= 0x80, so multi-byte characters pass through raw.
    private static func writeString(bytes: [UInt8], into out: inout [UInt8]) {
        out.append(0x22)
        for byte in bytes {
            switch byte {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])  // \"
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])  // \\
            case 0x08: out.append(contentsOf: [0x5C, 0x62])  // \b
            case 0x0C: out.append(contentsOf: [0x5C, 0x66])  // \f
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])  // \n
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])  // \r
            case 0x09: out.append(contentsOf: [0x5C, 0x74])  // \t
            case 0x00..<0x20:
                out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]])
            default:
                out.append(byte)
            }
        }
        out.append(0x22)
    }
}
