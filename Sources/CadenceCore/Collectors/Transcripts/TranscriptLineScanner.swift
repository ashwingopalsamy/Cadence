import Foundation

/// The five facts Cadence keeps from one Claude Code transcript line (docs/SPEC.md section 10.4).
struct TranscriptUsageLine: Sendable, Equatable {
    var messageID: String
    var model: String?
    var sessionID: String?
    /// Whole seconds since the epoch.
    var timestamp: Int64
    var input: Int64
    var output: Int64
    var cacheRead: Int64
    var cacheWrite: Int64
}

/// A targeted scanner for one transcript line. It walks the bytes and builds a value only for `timestamp`,
/// `sessionId`, `message.id`, `message.model` and the four `message.usage` counters. Everything else, message
/// content above all, is stepped over by counting brackets and skipping strings: it is never decoded, never
/// converted to a String and never validated, so it cannot end up in memory as data.
enum TranscriptLineScanner {
    /// Longest string the scanner will build. Ids, models, session ids and timestamps are short.
    static let maxString = 4096

    /// The line's facts, or nil when the line is malformed, has no `message.id`, no `message.usage` or no usable
    /// `timestamp`.
    static func scan(_ line: [UInt8]) -> TranscriptUsageLine? {
        line.withUnsafeBufferPointer { scan($0) }
    }

    static func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> TranscriptUsageLine? {
        var c = Cursor(bytes)
        guard c.consume(open) else { return nil }
        var timestamp: String?
        var session: String?
        var message: Message?
        if !c.consume(close) {
            while true {
                guard let key = c.string(), c.consume(colon) else { return nil }
                switch key {
                case "timestamp":
                    guard let v = c.stringOrSkip() else { return nil }
                    timestamp = v
                case "sessionId":
                    guard let v = c.stringOrSkip() else { return nil }
                    session = v
                case "message":
                    if c.peek() == open {
                        guard let m = scanMessage(&c) else { return nil }
                        message = m
                    } else {
                        guard c.skipValue() else { return nil }
                        message = nil
                    }
                default:
                    guard c.skipValue() else { return nil }
                }
                if c.consume(comma) { continue }
                guard c.consume(close) else { return nil }
                break
            }
        }
        guard let message, let id = message.id, !id.isEmpty, let usage = message.usage,
            let timestamp, let date = Timestamp.parse(timestamp)
        else { return nil }
        return TranscriptUsageLine(
            messageID: id, model: message.model, sessionID: session.flatMap { $0.isEmpty ? nil : $0 },
            timestamp: Int64(date.timeIntervalSince1970.rounded(.down)), input: usage.input, output: usage.output,
            cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite)
    }

    private struct Usage {
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
    }

    private struct Message {
        var id: String?
        var model: String?
        var usage: Usage?
    }

    private static func scanMessage(_ c: inout Cursor) -> Message? {
        guard c.consume(open) else { return nil }
        var message = Message()
        if c.consume(close) { return message }
        while true {
            guard let key = c.string(), c.consume(colon) else { return nil }
            switch key {
            case "id":
                guard let v = c.stringOrSkip() else { return nil }
                message.id = v
            case "model":
                guard let v = c.stringOrSkip() else { return nil }
                message.model = v
            case "usage":
                if c.peek() == open {
                    guard let u = scanUsage(&c) else { return nil }
                    message.usage = u
                } else {
                    guard c.skipValue() else { return nil }
                    message.usage = nil
                }
            default:
                guard c.skipValue() else { return nil }
            }
            if c.consume(comma) { continue }
            guard c.consume(close) else { return nil }
            return message
        }
    }

    private static func scanUsage(_ c: inout Cursor) -> Usage? {
        guard c.consume(open) else { return nil }
        var usage = Usage()
        if c.consume(close) { return usage }
        while true {
            guard let key = c.string(), c.consume(colon) else { return nil }
            switch key {
            case "input_tokens": guard let n = c.count() else { return nil }; usage.input = n
            case "output_tokens": guard let n = c.count() else { return nil }; usage.output = n
            case "cache_creation_input_tokens": guard let n = c.count() else { return nil }; usage.cacheWrite = n
            case "cache_read_input_tokens": guard let n = c.count() else { return nil }; usage.cacheRead = n
            default: guard c.skipValue() else { return nil }
            }
            if c.consume(comma) { continue }
            guard c.consume(close) else { return nil }
            return usage
        }
    }

    private static let open = UInt8(ascii: "{")
    private static let close = UInt8(ascii: "}")
    private static let colon = UInt8(ascii: ":")
    private static let comma = UInt8(ascii: ",")

    // MARK: Cursor

    private struct Cursor {
        let b: UnsafeBufferPointer<UInt8>
        var i = 0

        init(_ b: UnsafeBufferPointer<UInt8>) { self.b = b }

        private mutating func skipSpace() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        mutating func peek() -> UInt8? {
            skipSpace()
            return i < b.count ? b[i] : nil
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard peek() == byte else { return false }
            i += 1
            return true
        }

        /// Steps over the string whose opening quote is at `i`.
        private mutating func skipString() -> Bool {
            i += 1
            while i < b.count {
                switch b[i] {
                case 0x5C: i += 2
                case 0x22:
                    i += 1
                    return true
                default: i += 1
                }
            }
            return false
        }

        /// Steps over any value without building anything.
        mutating func skipValue() -> Bool {
            guard let first = peek() else { return false }
            switch first {
            case 0x22:
                return skipString()
            case 0x7B, 0x5B:
                var depth = 0
                while i < b.count {
                    switch b[i] {
                    case 0x22:
                        guard skipString() else { return false }
                        continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D: depth -= 1
                    default: break
                    }
                    i += 1
                    if depth == 0 { return true }
                }
                return false
            case 0x7D, 0x5D, 0x2C, 0x3A:
                return false
            default:
                let start = i
                while i < b.count, !(b[i] == 0x2C || b[i] == 0x7D || b[i] == 0x5D || b[i] <= 0x20) { i += 1 }
                return i > start
            }
        }

        /// A string value. Only used for keys and the targeted fields.
        mutating func string() -> String? {
            guard peek() == 0x22 else { return nil }
            i += 1
            var out: [UInt8] = []
            while i < b.count {
                let ch = b[i]
                if ch == 0x22 {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if out.count > TranscriptLineScanner.maxString { return nil }
                guard ch == 0x5C else {
                    out.append(ch)
                    i += 1
                    continue
                }
                guard i + 1 < b.count else { return nil }
                let esc = b[i + 1]
                i += 2
                switch esc {
                case 0x22, 0x5C, 0x2F: out.append(esc)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75:
                    guard var unit = hex4() else { return nil }
                    if (0xD800..<0xDC00).contains(unit), i + 1 < b.count, b[i] == 0x5C, b[i + 1] == 0x75 {
                        let save = i
                        i += 2
                        if let low = hex4(), (0xDC00..<0xE000).contains(low) {
                            unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            i = save
                        }
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(unit) ?? "\u{FFFD}").utf8))
                default: return nil
                }
            }
            return nil
        }

        private mutating func hex4() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            var v: UInt32 = 0
            for k in 0..<4 {
                let ch = b[i + k]
                let d: UInt32
                switch ch {
                case 0x30...0x39: d = UInt32(ch - 0x30)
                case 0x41...0x46: d = UInt32(ch - 0x41 + 10)
                case 0x61...0x66: d = UInt32(ch - 0x61 + 10)
                default: return nil
                }
                v = v << 4 | d
            }
            i += 4
            return v
        }

        /// A targeted string field: its text, or nil inside when the value is not a string (then skipped).
        /// The outer nil means the line is malformed.
        mutating func stringOrSkip() -> String?? {
            if peek() == 0x22 {
                guard let s = string() else { return nil }
                return .some(s)
            }
            return skipValue() ? .some(nil) : nil
        }

        /// A non-negative integer token count. Anything else (a float, a negative, text) makes the line unusable.
        mutating func count() -> Int64? {
            guard peek() != nil else { return nil }
            var n: Int64 = 0
            let start = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                let (m, o1) = n.multipliedReportingOverflow(by: 10)
                let (s, o2) = m.addingReportingOverflow(Int64(b[i] - 0x30))
                if o1 || o2 { return nil }
                n = s
                i += 1
            }
            guard i > start else { return nil }
            if i < b.count, !(b[i] == 0x2C || b[i] == 0x7D || b[i] <= 0x20) { return nil }
            return n
        }
    }
}
