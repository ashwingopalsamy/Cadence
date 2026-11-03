/// Applies ledger events to the projection tables (docs/SPEC.md section 7.3).
///
/// The ledger calls `apply` inside the same transaction that appends the event, and
/// `cadence rebuild` calls `reset` and then `apply` for every event in order. Projections are a
/// pure function of the event sequence, so a rebuild reproduces them byte for byte.
public protocol Projector {
    func apply(_ event: Event, in db: SQLiteDatabase) throws(CadenceError)
    /// Empties every projection table.
    func reset(in db: SQLiteDatabase) throws(CadenceError)
}

/// A projector that ignores every event. Used by ledger tests that only care about the chain.
public struct NoProjector: Projector {
    public init() {}
    public func apply(_ event: Event, in db: SQLiteDatabase) throws(CadenceError) {}
    public func reset(in db: SQLiteDatabase) throws(CadenceError) {}
}
