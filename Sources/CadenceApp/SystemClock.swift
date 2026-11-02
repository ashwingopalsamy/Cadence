import CadenceCore
import Foundation

/// The wall clock. The app creates it once at launch; Core and the view models receive it as a `Clock`.
struct SystemClock: Clock {
    func now() -> Date { Date() }
}
