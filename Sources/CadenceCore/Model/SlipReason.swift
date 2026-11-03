/// The reason chips the wrap-up offers when a task moves to tomorrow (docs/SPEC.md section 4.5), in the order they
/// are shown. They are a fixed list over free text: the ledger keeps any reason string, so a stored reason is a chip
/// only when it equals a raw value exactly, and anything else is the person's own words.
public enum SlipReason: String, Sendable, Hashable, CaseIterable, Codable {
    case reprioritised, blocked
    case tooBig = "too_big"
    case waitingOnSomeone = "waiting_on_someone"

    /// What the chip reads.
    public var label: String {
        switch self {
        case .reprioritised: "Reprioritised"
        case .blocked: "Blocked"
        case .tooBig: "Too big"
        case .waitingOnSomeone: "Waiting on someone"
        }
    }

    /// The chip a stored reason stands for, or nil when it is free text.
    public init?(stored reason: String) {
        self.init(rawValue: reason)
    }
}
