import Foundation

/// ULIDs (26 Crockford base32 characters): 48-bit Unix milliseconds, then 80 random bits.
public enum ULID {
    static let alphabet: [UInt8] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    static let maxMilliseconds: UInt64 = (1 << 48) - 1

    public static func make(at date: Date, random: any RandomSource) -> String {
        encode(milliseconds: milliseconds(of: date), entropy: entropy(from: random))
    }

    public static func isValid(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count == 26, bytes[0] <= UInt8(ascii: "7") else { return false }
        return bytes.allSatisfy { alphabet.contains($0) }
    }

    /// The embedded time, at millisecond precision. Nil when `s` is not a valid ULID.
    public static func timestamp(of s: String) -> Date? {
        guard isValid(s) else { return nil }
        var ms: UInt64 = 0
        for byte in s.utf8.prefix(10) {
            guard let index = alphabet.firstIndex(of: byte) else { return nil }
            ms = ms << 5 | UInt64(index)
        }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    static func entropy(from random: any RandomSource) -> [UInt8] {
        var e = random.bytes(10)
        if e.count < 10 { e += [UInt8](repeating: 0, count: 10 - e.count) }
        return Array(e.prefix(10))
    }

    static func milliseconds(of date: Date) -> UInt64 {
        let ms = (date.timeIntervalSince1970 * 1000).rounded(.down)
        guard ms.isFinite, ms > 0 else { return 0 }
        if ms >= Double(maxMilliseconds) { return maxMilliseconds }
        return UInt64(ms)
    }

    /// 130 bits (2 leading zero bits, 48 time bits, 80 entropy bits) as 26 groups of 5.
    static func encode(milliseconds: UInt64, entropy: [UInt8]) -> String {
        var bytes: [UInt8] = []
        for shift in stride(from: 40, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: milliseconds >> UInt64(shift)))
        }
        bytes += entropy
        var out: [UInt8] = []
        out.reserveCapacity(26)
        var buffer: UInt32 = 0
        var bits = 2  // two implicit leading zero bits
        for byte in bytes {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Monotonic within one process: ids made in the same millisecond strictly increase.
public final class ULIDGenerator: @unchecked Sendable {
    private let clock: any Clock
    private let random: any RandomSource
    private let lock = NSLock()
    private var lastMilliseconds: UInt64 = 0
    private var lastEntropy: [UInt8] = []

    public init(clock: any Clock, random: any RandomSource) {
        self.clock = clock
        self.random = random
    }

    public func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        var ms = ULID.milliseconds(of: clock.now())
        if !lastEntropy.isEmpty, ms <= lastMilliseconds {
            // Same millisecond (or a clock that moved back): keep the time, bump the random part.
            ms = lastMilliseconds
            if !increment(&lastEntropy) {
                ms = min(ms + 1, ULID.maxMilliseconds)
                lastEntropy = ULID.entropy(from: random)
            }
        } else {
            lastEntropy = ULID.entropy(from: random)
        }
        lastMilliseconds = ms
        return ULID.encode(milliseconds: ms, entropy: lastEntropy)
    }

    /// Adds one to a big-endian byte string. False on overflow.
    private func increment(_ bytes: inout [UInt8]) -> Bool {
        for i in stride(from: bytes.count - 1, through: 0, by: -1) {
            if bytes[i] < 255 {
                bytes[i] += 1
                return true
            }
            bytes[i] = 0
        }
        return false
    }
}
