import Foundation

public struct PresenceBackfillResult: Sendable, Equatable {
    public var written: Int
    /// Spans that were already in the ledger (or repeated in the input).
    public var skipped: Int
}

extension Journal {
    /// Appends one `presence.span` event (source `powerlog`) for each span, in one transaction. A span whose
    /// day, start, end and source match an existing row is skipped, so a second run writes nothing.
    /// A day after today, or a span that ends after now, refuses the whole batch.
    public func backfillPresence(spans: [PowerLogSpan], actor: Actor = .cli) throws(CadenceError) -> PresenceBackfillResult {
        let today = self.today()
        let now = clock.now()
        let zone = self.zone
        var payloads: [PresenceSpanPayload] = []
        for span in spans {
            guard span.day <= today else { throw .validation("presence: \(span.day) is in the future") }
            guard span.end <= now else { throw .validation("presence: a span on \(span.day) ends in the future") }
            let payload = PresenceSpanPayload(
                day: span.day.description, tz: zone.identifier, start: Timestamp.local(span.start, in: zone),
                end: Timestamp.local(span.end, in: zone), source: .powerlog)
            _ = try PresenceSpanPayload(json: payload.json)
            payloads.append(payload)
        }
        guard !payloads.isEmpty else { return PresenceBackfillResult(written: 0, skipped: 0) }

        return try store.transact { () throws(CadenceError) -> PresenceBackfillResult in
            var seen = Set<String>()
            var drafts: [EventDraft] = []
            var skipped = 0
            for payload in payloads {
                let key = [payload.day, payload.start, payload.end, payload.source.rawValue].joined(separator: "|")
                let exists = try self.rows(
                    "SELECT 1 AS found FROM presence_spans WHERE day = ? AND start_at = ? AND end_at = ? AND source = ? LIMIT 1",
                    [.text(payload.day), .text(payload.start), .text(payload.end), .text(payload.source.rawValue)]
                ).first != nil
                if exists || !seen.insert(key).inserted {
                    skipped += 1
                    continue
                }
                drafts.append(EventPayload.presenceSpan(payload).draft(actor: actor))
            }
            if !drafts.isEmpty { try self.append(drafts) }
            return PresenceBackfillResult(written: drafts.count, skipped: skipped)
        }
    }
}
