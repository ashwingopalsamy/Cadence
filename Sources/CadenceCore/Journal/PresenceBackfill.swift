import Foundation

public struct PresenceBackfillResult: Sendable, Equatable {
    public var written: Int
    /// Spans the ledger already covered (or repeated in the input).
    public var skipped: Int
}

extension Journal {
    /// Appends `presence.span` events (source `powerlog`) for what each span adds, in one transaction. A span the day's
    /// rows already cover is skipped, so a second run writes nothing and observed presence is not doubled.
    /// A day after today, or a span that ends after now, refuses the whole batch.
    public func backfillPresence(spans: [PowerLogSpan], actor: Actor = .cli) throws(CadenceError) -> PresenceBackfillResult {
        let today = self.today()
        let now = clock.now()
        for span in spans {
            guard span.day <= today else { throw .validation("presence: \(span.day) is in the future") }
            guard span.end <= now else { throw .validation("presence: a span on \(span.day) ends in the future") }
        }
        guard !spans.isEmpty else { return PresenceBackfillResult(written: 0, skipped: 0) }

        // Only what no span of the day covers, appended one by one so a span also sees the ones before it. Power log
        // spans keep any length, and observed presence already in the ledger is not doubled.
        return try store.transact { () throws(CadenceError) -> PresenceBackfillResult in
            var written = 0
            var skipped = 0
            for span in spans {
                let pieces = try self.uncoveredPresence(from: span.start, to: span.end, minimum: 1) ?? []
                if pieces.isEmpty { skipped += 1 }
                for piece in pieces {
                    let payload = PresenceSpanPayload(
                        day: piece.day.description, tz: piece.zone.identifier, start: Timestamp.local(piece.start, in: piece.zone),
                        end: Timestamp.local(piece.end, in: piece.zone), source: .powerlog)
                    _ = try PresenceSpanPayload(json: payload.json)
                    try self.append([EventPayload.presenceSpan(payload).draft(actor: actor)])
                    written += 1
                }
            }
            return PresenceBackfillResult(written: written, skipped: skipped)
        }
    }
}
