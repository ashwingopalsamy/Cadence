/// SHA-256 over bytes, behind a protocol so Core never imports a crypto library directly
/// (docs/SPEC.md section 7.3: CryptoKit on macOS, swift-crypto on Linux).
///
/// The spec calls this `Hasher`; it is named `ContentHasher` so it does not shadow
/// `Swift.Hasher`, which every `Hashable` conformance in this module uses.
public protocol ContentHasher: Sendable {
    /// Lowercase hex SHA-256 of `bytes`: 64 characters.
    func sha256Hex(_ bytes: [UInt8]) -> String
}
