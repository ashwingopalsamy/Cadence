import Foundation

/// JSON that remembers member order and the exact text of every number.
///
/// `~/.claude/settings.json` and `~/.claude.json` belong to the user and to Claude Code, so Cadence edits them
/// without reordering keys, rounding numbers or dropping members. `JSONValue` cannot do that: it keeps objects
/// in a dictionary and refuses fractions. This type is for reading and rewriting those files only; the ledger
/// never uses it.
///
/// The reader is strict RFC 8259 (no comments, no trailing commas) and keeps duplicate keys. The writer matches
/// Claude Code's own output: two-space indent, one member or element per line.
public indirect enum OrderedJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// The number exactly as written.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: OrderedJSON

        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    /// Nesting deeper than this is refused, so a hostile file cannot exhaust the stack.
    public static let maxDepth = 128

    // MARK: reading values

    /// The value of the last member with this key, as JavaScript's `JSON.parse` would see it. Nil for other values.
    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    public var members: [Member]? {
        if case .object(let members) = self { return members }
        return nil
    }

    public var arrayValue: [OrderedJSON]? {
        if case .array(let elements) = self { return elements }
        return nil
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// The value of a number, nil for anything that is not one.
    public var doubleValue: Double? {
        if case .number(let text) = self { return Double(text) }
        return nil
    }

    /// Replaces the last member with this key, or appends one. False, and no change, when this is not an object.
    @discardableResult
    public mutating func setMember(_ key: String, _ value: OrderedJSON) -> Bool {
        guard case .object(var members) = self else { return false }
        if let index = members.lastIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append(Member(key, value))
        }
        self = .object(members)
        return true
    }

    // MARK: parsing

    /// Parses one JSON document. Failures are `validation` errors that start with "not valid JSON" and name the line.
    public static func parse(_ bytes: [UInt8]) throws(CadenceError) -> OrderedJSON {
        var parser = Parser(bytes: bytes)
        return try parser.document()
    }

    struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        func failure(_ reason: String) -> CadenceError {
            var line = 1
            var lineStart = 0
            for (offset, byte) in bytes.prefix(min(index, bytes.count)).enumerated() where byte == 0x0A {
                line += 1
                lineStart = offset + 1
            }
            return .validation("not valid JSON at line \(line), column \(min(index, bytes.count) - lineStart + 1): \(reason)")
        }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func document() throws(CadenceError) -> OrderedJSON {
            skipSpace()
            guard index < bytes.count else { throw failure("the file is empty") }
            let value = try value(depth: 0)
            skipSpace()
            guard index == bytes.count else { throw failure("unexpected text after the value") }
            return value
        }

        mutating func value(depth: Int) throws(CadenceError) -> OrderedJSON {
            guard depth <= OrderedJSON.maxDepth else { throw failure("nested too deeply") }
            guard index < bytes.count else { throw failure("the text ends early") }
            switch bytes[index] {
            case 0x7B: return try object(depth: depth)
            case 0x5B: return try array(depth: depth)
            case 0x22: return .string(try string())
            case 0x74: try word("true"); return .bool(true)
            case 0x66: try word("false"); return .bool(false)
            case 0x6E: try word("null"); return .null
            case 0x2D, 0x30...0x39: return .number(try number())
            default: throw failure("unexpected character")
            }
        }

        mutating func word(_ text: String) throws(CadenceError) {
            let expected = Array(text.utf8)
            guard bytes.count - index >= expected.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw failure("unexpected character")
            }
            index += expected.count
        }

        mutating func number() throws(CadenceError) -> String {
            let start = index
            func digits(_ parser: inout Parser) -> Int {
                var count = 0
                while parser.index < parser.bytes.count, (0x30...0x39).contains(parser.bytes[parser.index]) {
                    parser.index += 1
                    count += 1
                }
                return count
            }
            if bytes[index] == 0x2D { index += 1 }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw failure("a number needs digits") }
            if bytes[index] == 0x30 {
                index += 1
                if index < bytes.count, (0x30...0x39).contains(bytes[index]) { throw failure("a number cannot start with 0") }
            } else {
                _ = digits(&self)
            }
            if index < bytes.count, bytes[index] == 0x2E {
                index += 1
                guard digits(&self) > 0 else { throw failure("a fraction needs digits") }
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
                guard digits(&self) > 0 else { throw failure("an exponent needs digits") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func hex4() throws(CadenceError) -> UInt32 {
            guard bytes.count - index >= 4 else { throw failure("a \\u escape needs four hex digits") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt32
                switch byte {
                case 0x30...0x39: digit = UInt32(byte - 0x30)
                case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
                case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
                default: throw failure("a \\u escape needs four hex digits")
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        mutating func string() throws(CadenceError) -> String {
            index += 1  // the opening quote
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw failure("a string is not closed") }
                let byte = bytes[index]
                switch byte {
                case 0x22:
                    index += 1
                    guard let text = String(bytes: out, encoding: .utf8) else { throw failure("a string is not valid UTF-8") }
                    return text
                case 0x00..<0x20:
                    throw failure("a string holds a raw control character")
                case 0x5C:
                    index += 1
                    guard index < bytes.count else { throw failure("a string is not closed") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case 0x22, 0x5C, 0x2F: out.append(escape)
                    case 0x62: out.append(0x08)
                    case 0x66: out.append(0x0C)
                    case 0x6E: out.append(0x0A)
                    case 0x72: out.append(0x0D)
                    case 0x74: out.append(0x09)
                    case 0x75:
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code) {
                            guard bytes.count - index >= 6, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                                throw failure("a lone surrogate in a string")
                            }
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw failure("a lone surrogate in a string") }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(code) {
                            throw failure("a lone surrogate in a string")
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw failure("an invalid character code") }
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default:
                        index -= 1
                        throw failure("an unknown escape in a string")
                    }
                default:
                    out.append(byte)
                    index += 1
                }
            }
        }

        mutating func array(depth: Int) throws(CadenceError) -> OrderedJSON {
            index += 1
            var elements: [OrderedJSON] = []
            skipSpace()
            if index < bytes.count, bytes[index] == 0x5D {
                index += 1
                return .array(elements)
            }
            while true {
                skipSpace()
                elements.append(try value(depth: depth + 1))
                skipSpace()
                guard index < bytes.count else { throw failure("an array is not closed") }
                if bytes[index] == 0x2C {
                    index += 1
                } else if bytes[index] == 0x5D {
                    index += 1
                    return .array(elements)
                } else {
                    throw failure("expected a comma or ] in an array")
                }
            }
        }

        mutating func object(depth: Int) throws(CadenceError) -> OrderedJSON {
            index += 1
            var members: [Member] = []
            skipSpace()
            if index < bytes.count, bytes[index] == 0x7D {
                index += 1
                return .object(members)
            }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == 0x22 else { throw failure("expected a quoted key") }
                let key = try string()
                skipSpace()
                guard index < bytes.count, bytes[index] == 0x3A else { throw failure("expected a colon after a key") }
                index += 1
                skipSpace()
                members.append(Member(key, try value(depth: depth + 1)))
                skipSpace()
                guard index < bytes.count else { throw failure("an object is not closed") }
                if bytes[index] == 0x2C {
                    index += 1
                } else if bytes[index] == 0x7D {
                    index += 1
                    return .object(members)
                } else {
                    throw failure("expected a comma or } in an object")
                }
            }
        }
    }

    // MARK: writing

    /// Pretty-printed text without a trailing newline.
    public func serialized(indent: Int = 2) -> String {
        var out = ""
        write(into: &out, level: 0, indent: indent)
        return out
    }

    private func write(into out: inout String, level: Int, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .number(let text): out += text
        case .string(let text): Self.writeString(text, into: &out)
        case .array(let elements):
            guard !elements.isEmpty else {
                out += "[]"
                return
            }
            out += "[\n"
            for (offset, element) in elements.enumerated() {
                out += String(repeating: " ", count: (level + 1) * indent)
                element.write(into: &out, level: level + 1, indent: indent)
                out += offset == elements.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: level * indent) + "]"
        case .object(let members):
            guard !members.isEmpty else {
                out += "{}"
                return
            }
            out += "{\n"
            for (offset, member) in members.enumerated() {
                out += String(repeating: " ", count: (level + 1) * indent)
                Self.writeString(member.key, into: &out)
                out += ": "
                member.value.write(into: &out, level: level + 1, indent: indent)
                out += offset == members.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: level * indent) + "}"
        }
    }

    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
