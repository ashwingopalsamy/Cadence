#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// SHA-256 from CryptoKit on macOS and swift-crypto elsewhere (docs/SPEC.md section 8.5).
public struct SHA256Hasher: ContentHasher {
    public init() {}

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    public func sha256Hex(_ bytes: [UInt8]) -> String {
        let digest = SHA256.hash(data: bytes)
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(Self.hexDigits[Int(byte >> 4)])
            hex.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}
