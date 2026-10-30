/// The ledger-facing surface of the Cadence store (docs/SPEC.md sections 7.3 and 8.2).
///
/// Implementations append under `BEGIN IMMEDIATE`, so SQLite serialises every writer across
/// processes: the previous hash is read and the new events are written, with their projection
/// updates, inside one transaction. Projection reads are added alongside the projections (T1.8).
public protocol Store: AnyObject {
    /// The schema version the store is at (`PRAGMA user_version`).
    func schemaVersion() throws -> Int

    /// Appends events atomically, in order, and applies them to the projections in the same
    /// transaction. Returns the stored events. Throws `CadenceError.storeBusy` when another
    /// writer holds the lock past the busy timeout.
    @discardableResult
    func append(_ drafts: [EventDraft]) throws -> [Event]

    /// The last event, or nil for an empty ledger.
    func head() throws -> Event?

    /// Events with `seq > after`, in order, at most `limit`.
    func events(after seq: Int64, limit: Int) throws -> [Event]
}
