import CadenceCore
import Foundation

/// The wall clock. Only the CLI entry point creates one; Core receives it as a `Clock`.
struct SystemClock: Clock {
    func now() -> Date { Date() }
}
