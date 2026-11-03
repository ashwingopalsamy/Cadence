import Foundation
import Testing

@testable import CadenceCore

@Suite struct ULIDTests {
    private let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Independent encoder: repeated division by 32, ten digits.
    private func prefix(forMilliseconds ms: UInt64) -> String {
        var value = ms
        var digits: [Character] = []
        for _ in 0..<10 {
            digits.append(alphabet[Int(value % 32)])
            value /= 32
        }
        return String(digits.reversed())
    }

    @Test func deterministicWithSeededRandom() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = ULID.make(at: date, random: SeededRandomSource(seed: 7))
        let b = ULID.make(at: date, random: SeededRandomSource(seed: 7))
        let c = ULID.make(at: date, random: SeededRandomSource(seed: 8))
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 26)
        #expect(ULID.isValid(a))
    }

    @Test func zeroTimeEncodesAsZeros() {
        let id = ULID.make(at: Date(timeIntervalSince1970: 0), random: SeededRandomSource(seed: 1))
        #expect(id.hasPrefix("0000000000"))
        #expect(ULID.timestamp(of: id) == Date(timeIntervalSince1970: 0))
    }

    @Test func knownTimestampPrefix() {
        let ms: UInt64 = 1_700_000_000_000
        let expected = prefix(forMilliseconds: ms)
        let id = ULID.make(at: Date(timeIntervalSince1970: 1_700_000_000), random: SeededRandomSource(seed: 3))
        #expect(String(id.prefix(10)) == expected)
        #expect(expected == "01HF7YAT00")
    }

    @Test func randomPartUsesAllEightyBits() {
        struct Fixed: RandomSource {
            let byte: UInt8
            func bytes(_ count: Int) -> [UInt8] { [UInt8](repeating: byte, count: count) }
        }
        let zeros = ULID.make(at: Date(timeIntervalSince1970: 0), random: Fixed(byte: 0))
        #expect(zeros == String(repeating: "0", count: 26))
        let ones = ULID.make(at: Date(timeIntervalSince1970: 0), random: Fixed(byte: 255))
        #expect(ones == "0000000000" + String(repeating: "Z", count: 16))
    }

    @Test func clampsOutOfRangeDates() {
        let early = ULID.make(at: Date(timeIntervalSince1970: -5000), random: SeededRandomSource(seed: 1))
        #expect(early.hasPrefix("0000000000"))
        let late = ULID.make(at: Date(timeIntervalSince1970: 1e15), random: SeededRandomSource(seed: 1))
        #expect(late.hasPrefix("7ZZZZZZZZZ"))
        #expect(ULID.isValid(late))
    }

    @Test func validation() {
        let good = ULID.make(at: Date(timeIntervalSince1970: 1_700_000_000), random: SeededRandomSource(seed: 1))
        #expect(ULID.isValid(good))
        #expect(!ULID.isValid(good.lowercased()))
        #expect(!ULID.isValid(String(good.dropLast())))
        #expect(!ULID.isValid(good + "0"))
        #expect(!ULID.isValid(""))
        for bad in ["I", "L", "O", "U"] {
            #expect(!ULID.isValid(String(good.dropLast()) + bad))
        }
        #expect(!ULID.isValid("8" + String(repeating: "0", count: 25)))
        #expect(ULID.isValid("7" + String(repeating: "Z", count: 25)))
        #expect(ULID.timestamp(of: "not a ulid") == nil)
    }

    @Test func timestampRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_761_753_731.123)
        let id = ULID.make(at: date, random: SeededRandomSource(seed: 9))
        let back = ULID.timestamp(of: id)
        #expect(back != nil)
        #expect(abs((back ?? .distantPast).timeIntervalSince1970 - 1_761_753_731.123) < 0.001)
    }

    @Test func generatorIsMonotonicAtAFrozenClock() {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_700_000_000))
        let generator = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 42))
        var previous = generator.next()
        #expect(ULID.isValid(previous))
        for _ in 0..<999 {
            let id = generator.next()
            #expect(ULID.isValid(id))
            #expect(id > previous)
            #expect(String(id.prefix(10)) == String(previous.prefix(10)))
            previous = id
        }
    }

    @Test func generatorFollowsTheClockAndNeverGoesBack() {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_700_000_000))
        let generator = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
        let first = generator.next()
        clock.advance(by: 1)
        let second = generator.next()
        #expect(second > first)
        #expect(ULID.timestamp(of: second) == Date(timeIntervalSince1970: 1_700_000_001))
        clock.set(Date(timeIntervalSince1970: 1_600_000_000))
        let third = generator.next()
        #expect(third > second)
    }

    @Test func generatorCarriesOnRandomOverflow() {
        struct Max: RandomSource {
            func bytes(_ count: Int) -> [UInt8] { [UInt8](repeating: 255, count: count) }
        }
        let clock = ManualClock(Date(timeIntervalSince1970: 100))
        let generator = ULIDGenerator(clock: clock, random: Max())
        let first = generator.next()
        let second = generator.next()
        #expect(second > first)
        #expect(ULID.isValid(second))
    }
}
