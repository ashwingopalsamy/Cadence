/// Every failure Cadence reports. Each case maps to one CLI exit code (docs/SPEC.md section 9.5)
/// and to one MCP error result.
public enum CadenceError: Error, Equatable, Sendable {
    /// Bad command-line usage or an unknown option.
    case usage(String)
    /// Input that breaks a rule: a bad envelope record, an invalid config, a malformed date.
    case validation(String)
    /// Another writer held the store past `busy_timeout`.
    case storeBusy
    /// A day, entry, task or file that does not exist.
    case notFound(String)
    /// The store was written by a newer Cadence. This binary refuses to write to it.
    case schemaTooNew(found: Int, supported: Int)
    /// The ledger or a proof file failed an integrity check.
    case integrity(String)
    /// An operating-system or SQLite failure that is not the caller's fault.
    case io(String)

    /// CLI exit codes: 0 ok, 1 usage, 2 validation, 3 store busy, 4 not found.
    /// Integrity and newer-schema failures are validation failures from the caller's point of view;
    /// I/O failures share the general failure code.
    public var exitCode: Int32 {
        switch self {
        case .usage, .io: 1
        case .validation, .schemaTooNew, .integrity: 2
        case .storeBusy: 3
        case .notFound: 4
        }
    }

    public var message: String {
        switch self {
        case .usage(let m): m
        case .validation(let m): m
        case .storeBusy: "the store is busy; another Cadence process is writing. Try again."
        case .notFound(let m): m
        case .schemaTooNew(let found, let supported):
            "the store uses schema \(found) but this cadence supports up to \(supported); update cadence"
        case .integrity(let m): m
        case .io(let m): m
        }
    }
}
