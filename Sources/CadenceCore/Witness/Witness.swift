import Foundation

/// A witness code: the first 16 hex characters of a `witness.checkpoint` event's hash
/// (docs/SPEC.md sections 4.5 and 12.1).
///
/// The stand-up text ends with `cadence <code>`. Slack, not the owner, timestamps that message, so a
/// code found in the chain shows the ledger up to that checkpoint existed by the message's time.
/// The proof verifier accepts a code that is a prefix of any event hash in the exported chain.
public struct Witness: Sendable, Equatable {
    public static let codeLength = 16
    /// The purpose the stand-up copy uses.
    public static let standUp = "stand-up"

    /// The day the checkpoint was made for (the stand-up's day).
    public let date: LocalDate
    public let code: String
    public let purpose: String
    public let eventHash: String
    public let seq: Int64

    /// The last line of the stand-up text.
    public var line: String { "cadence \(code)" }

    /// Where the code was posted, as the proof file names it.
    public var `where`: String { purpose == Witness.standUp ? "stand-up message" : purpose }

    public static func code(of hash: String) -> String { String(hash.prefix(codeLength)) }

    init?(_ event: Event) {
        guard event.type == "witness.checkpoint",
            case .witness(let payload)? = try? EventPayload(type: event.type, data: event.data),
            let date = LocalDate(payload.day)
        else { return nil }
        self.date = date
        self.code = Witness.code(of: event.hash)
        self.purpose = payload.purpose
        self.eventHash = event.hash
        self.seq = event.seq
    }

    /// Accepts the bare code or the whole `cadence <code>` line, in either case, as pasted from a chat:
    /// surrounding backticks, quotes, punctuation and any kind of space are ignored.
    static func normalise(_ text: String) throws(CadenceError) -> String {
        let noise = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        var code = text.trimmingCharacters(in: noise).lowercased()
        if code.hasPrefix("cadence"), code.count > 7 {
            code = String(code.dropFirst(7)).trimmingCharacters(in: noise)
        }
        guard code.utf8.count == codeLength, code.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else { throw .usage("a witness code is \(codeLength) hex characters") }
        return code
    }
}

extension SQLiteStore {
    /// Returns the witness for `day`, appending a `witness.checkpoint` unless the head already is one
    /// for the same day and purpose. Copying the stand-up twice with nothing new in between gives the
    /// same code, so the ledger does not grow on every copy.
    @discardableResult
    public func witness(day: LocalDate, purpose: String = Witness.standUp, actor: Actor) throws(CadenceError) -> Witness {
        let purposeOK = (1...32).contains(purpose.utf8.count)
            && purpose.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
        guard purposeOK else { throw .validation("a witness purpose is 1 to 32 lowercase letters, digits or hyphens") }
        return try transact { () throws(CadenceError) -> Witness in
            let head: Event?
            do { head = try self.head() } catch { throw (error as? CadenceError) ?? .io(String(describing: error)) }
            guard head != nil else { throw .integrity("the ledger is empty; write ledger.genesis first") }
            if let head, let existing = Witness(head), existing.date == day, existing.purpose == purpose {
                return existing
            }
            let payload = EventPayload.witness(WitnessCheckpoint(day: day.description, purpose: purpose))
            let events: [Event]
            do { events = try self.append([payload.draft(actor: actor)]) } catch {
                throw (error as? CadenceError) ?? .io(String(describing: error))
            }
            guard let event = events.first, let witness = Witness(event) else {
                throw .integrity("the witness checkpoint did not read back")
            }
            return witness
        }
    }

    /// Every witness checkpoint in ledger order, optionally only those for days in a range.
    public func witnesses(from: LocalDate? = nil, through: LocalDate? = nil) throws(CadenceError) -> [Witness] {
        try readEvents("SELECT * FROM events WHERE type = 'witness.checkpoint' ORDER BY seq", [])
            .compactMap(Witness.init)
            .filter { w in (from.map { w.date >= $0 } ?? true) && (through.map { w.date <= $0 } ?? true) }
    }

    /// The event whose hash starts with `witnessCode` (a code or a whole `cadence <code>` line).
    public func find(witnessCode: String) throws(CadenceError) -> Event? {
        let code = try Witness.normalise(witnessCode)
        // A range on the unique hash index: every hash with this prefix sorts between code and code + "g".
        return try readEvents(
            "SELECT * FROM events WHERE hash >= ? AND hash < ? ORDER BY seq LIMIT 1", [.text(code), .text(code + "g")]
        ).first
    }
}
