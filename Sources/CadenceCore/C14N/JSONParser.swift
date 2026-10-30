/// A strict JSON parser that produces `JSONValue` (RFC 8259 grammar, integers only).
///
/// Cadence never needs floating point, so a number with a fraction or exponent is rejected
/// rather than rounded, and so is an integer outside ±(2^53 - 1). Duplicate object keys,
/// invalid UTF-8, unpaired surrogate escapes and trailing content are rejected too. Used for
/// stored payloads, envelopes, MCP messages and config, so every input path shares one rulebook.
public struct JSONParser {
    public enum Failure: Error, Equatable, Sendable {
        case invalidUTF8
        case unexpectedEnd
        case unexpectedByte(UInt8, offset: Int)
        case floatNotAllowed(offset: Int)
        case integerOutOfRange(offset: Int)
        case invalidEscape(offset: Int)
        case unpairedSurrogate(offset: Int)
        case controlCharacterInString(offset: Int)
        case duplicateKey(String)
        case trailingContent(offset: Int)
        case tooDeep
    }

    /// The most containers that may nest, so hostile input cannot exhaust the stack.
    /// `CanonicalJSON` enforces the same limit, so anything written can be read back.
    public static let maxDepth = 64

    private let bytes: [UInt8]
    private var index = 0

    private init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public static func parse(_ text: String) throws(Failure) -> JSONValue {
        try parse(bytes: Array(text.utf8))
    }

    public static func parse(bytes: [UInt8]) throws(Failure) -> JSONValue {
        // Validate UTF-8 up front, so string decoding below can never meet a bad sequence.
        guard String(validating: bytes, as: UTF8.self) != nil else { throw .invalidUTF8 }
        var parser = JSONParser(bytes)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        if parser.index != parser.bytes.count { throw .trailingContent(offset: parser.index) }
        return value
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private func peek() throws(Failure) -> UInt8 {
        guard index < bytes.count else { throw .unexpectedEnd }
        return bytes[index]
    }

    private mutating func expect(_ literal: [UInt8]) throws(Failure) {
        for byte in literal {
            guard index < bytes.count else { throw .unexpectedEnd }
            guard bytes[index] == byte else { throw .unexpectedByte(bytes[index], offset: index) }
            index += 1
        }
    }

    private mutating func parseValue(depth: Int) throws(Failure) -> JSONValue {
        switch try peek() {
        case 0x7B:
            guard depth < JSONParser.maxDepth else { throw .tooDeep }
            return try parseObject(depth: depth + 1)
        case 0x5B:
            guard depth < JSONParser.maxDepth else { throw .tooDeep }
            return try parseArray(depth: depth + 1)
        case 0x22: return .string(try parseString())
        case 0x74: try expect([0x74, 0x72, 0x75, 0x65]); return .bool(true)
        case 0x66: try expect([0x66, 0x61, 0x6C, 0x73, 0x65]); return .bool(false)
        case 0x6E: try expect([0x6E, 0x75, 0x6C, 0x6C]); return .null
        case 0x2D, 0x30...0x39: return .int(try parseInteger())
        case let other: throw .unexpectedByte(other, offset: index)
        }
    }

    private mutating func parseObject(depth: Int) throws(Failure) -> JSONValue {
        index += 1  // {
        var object: [String: JSONValue] = [:]
        skipWhitespace()
        if try peek() == 0x7D {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard try peek() == 0x22 else { throw .unexpectedByte(bytes[index], offset: index) }
            let key = try parseString()
            skipWhitespace()
            try expect([0x3A])
            skipWhitespace()
            let value = try parseValue(depth: depth)
            // Swift compares Strings by canonical equivalence, so keys that differ only in Unicode
            // normalisation count as duplicates too: a dictionary could not hold both.
            if object[key] != nil {
                throw .duplicateKey(key)
            }
            object[key] = value
            skipWhitespace()
            switch try peek() {
            case 0x2C: index += 1
            case 0x7D: index += 1; return .object(object)
            case let other: throw .unexpectedByte(other, offset: index)
            }
        }
    }

    private mutating func parseArray(depth: Int) throws(Failure) -> JSONValue {
        index += 1  // [
        var items: [JSONValue] = []
        skipWhitespace()
        if try peek() == 0x5D {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue(depth: depth))
            skipWhitespace()
            switch try peek() {
            case 0x2C: index += 1
            case 0x5D: index += 1; return .array(items)
            case let other: throw .unexpectedByte(other, offset: index)
            }
        }
    }

    private mutating func parseInteger() throws(Failure) -> Int64 {
        let start = index
        var negative = false
        if bytes[index] == 0x2D {
            negative = true
            index += 1
        }
        guard index < bytes.count else { throw .unexpectedEnd }
        let firstDigit = bytes[index]
        guard (0x30...0x39).contains(firstDigit) else { throw .unexpectedByte(firstDigit, offset: index) }
        var magnitude: Int64 = 0
        var digits = 0
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            digits += 1
            if digits > 1 && firstDigit == 0x30 { throw .unexpectedByte(bytes[index], offset: index) }  // leading zero
            let digit = Int64(bytes[index] - 0x30)
            if magnitude > (JSONValue.maxSafeInteger - digit) / 10 { throw .integerOutOfRange(offset: start) }
            magnitude = magnitude * 10 + digit
            index += 1
        }
        if index < bytes.count, [0x2E, 0x65, 0x45].contains(bytes[index]) { throw .floatNotAllowed(offset: start) }
        return negative ? -magnitude : magnitude
    }

    private mutating func parseHex4() throws(Failure) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count else { throw .unexpectedEnd }
            let b = bytes[index]
            let nibble: UInt32
            switch b {
            case 0x30...0x39: nibble = UInt32(b - 0x30)
            case 0x41...0x46: nibble = UInt32(b - 0x41 + 10)
            case 0x61...0x66: nibble = UInt32(b - 0x61 + 10)
            default: throw .invalidEscape(offset: index)
            }
            value = value << 4 | nibble
            index += 1
        }
        return value
    }

    private mutating func parseString() throws(Failure) -> String {
        index += 1  // opening quote
        var out: [UInt8] = []
        while true {
            guard index < bytes.count else { throw .unexpectedEnd }
            let b = bytes[index]
            switch b {
            case 0x22:
                index += 1
                return String(decoding: out, as: UTF8.self)
            case 0x5C:
                let escapeStart = index
                index += 1
                guard index < bytes.count else { throw .unexpectedEnd }
                let e = bytes[index]
                index += 1
                switch e {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x2F: out.append(0x2F)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75:
                    var scalar = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                            throw .unpairedSurrogate(offset: escapeStart)
                        }
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw .unpairedSurrogate(offset: escapeStart) }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw .unpairedSurrogate(offset: escapeStart)
                    }
                    guard let unicode = Unicode.Scalar(scalar) else { throw .invalidEscape(offset: escapeStart) }
                    UTF8.encode(unicode) { out.append($0) }
                default:
                    throw .invalidEscape(offset: escapeStart)
                }
            case 0x00..<0x20:
                throw .controlCharacterInString(offset: index)
            default:
                out.append(b)
                index += 1
            }
        }
    }
}
