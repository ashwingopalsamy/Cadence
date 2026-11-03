/// Randomness for identifiers (ULIDs). Injected so tests are deterministic.
public protocol RandomSource: Sendable {
    /// Returns `count` random bytes.
    func bytes(_ count: Int) -> [UInt8]
}

/// Cryptographically secure randomness from the operating system.
public struct SystemRandomSource: RandomSource {
    public init() {}

    public func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

/// Deterministic randomness (SplitMix64) for tests and the demo seed. Not for production ids.
public final class SeededRandomSource: RandomSource, @unchecked Sendable {
    private var state: UInt64
    private let lock = NSLockShim()

    public init(seed: UInt64) {
        state = seed
    }

    public func bytes(_ count: Int) -> [UInt8] {
        lock.withLock {
            var out: [UInt8] = []
            out.reserveCapacity(count)
            while out.count < count {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
                for shift in stride(from: 56, through: 0, by: -8) where out.count < count {
                    out.append(UInt8(truncatingIfNeeded: z >> UInt64(shift)))
                }
            }
            return out
        }
    }
}
