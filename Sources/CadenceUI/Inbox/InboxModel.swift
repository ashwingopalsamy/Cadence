import CadenceCore
import Dispatch
import Foundation
import Observation

/// The Inbox's state, published on the main actor (docs/SPEC.md section 4.6).
///
/// Reads run on a background queue on a fresh read-only connection. Every decision and edit is written through
/// `AppState`, the app's one write path. A decision changes only the entry's status and an edit only its title: its
/// origin never changes. A decided entry leaves the list as soon as the ledger takes it, and the list is read again after.
@MainActor @Observable
public final class InboxModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case loaded
        case failed(StoreFailure)
    }

    public private(set) var phase: Phase = .loading
    /// Proposals waiting, newest first.
    public private(set) var entries: [Entry] = []
    public private(set) var today: LocalDate?
    /// Entries whose decision is being written, so their buttons wait.
    public private(set) var working: Set<String> = []
    /// Counts finished reads, so a caller can wait for the read after its change.
    public private(set) var reads = 0
    /// The proposal whose title is being edited in place, if any.
    public private(set) var edit: TitleEdit?

    @ObservationIgnored private let reader: JournalReader
    @ObservationIgnored private let queue = DispatchQueue(label: "in.ashwingopalsamy.cadence.inbox-model", qos: .userInitiated)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var started = false

    public init(location: StoreLocation, clock: any Clock) {
        reader = JournalReader(location: location, clock: clock)
    }

    /// How many proposals wait, for the toolbar's badge. Nil until the first read, since unknown is not zero.
    public var count: Int? { phase == .loaded ? entries.count : nil }

    /// Reads the Inbox once, when it first shows.
    public func start() {
        guard !started else { return }
        reload()
    }

    /// Reads the Inbox again, after a decision or a change to the store.
    public func reload() {
        started = true
        generation += 1
        let mine = generation
        Task {
            let result = await reader.read(on: queue) { (journal) throws(CadenceError) -> ([Entry], LocalDate) in
                (Array(try journal.inbox().reversed()), journal.today())
            }
            guard mine == generation else { return }
            switch result {
            case .success(let (entries, today)):
                self.entries = entries
                self.today = today
                phase = .loaded
                if let edit, !entries.contains(where: { $0.id == edit.entry }) { self.edit = nil }
            case .failure(let failure) where failure.kind == .missing:
                // No store yet is an empty Inbox, not a failure.
                entries = []
                phase = .loaded
            case .failure(let failure):
                entries = []
                phase = .failed(failure)
            }
            reads += 1
        }
    }

    // MARK: editing

    /// Turns a proposal's title into a field holding its words.
    public func beginEdit(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        edit = TitleEdit(entry: id, draft: entry.title)
    }

    /// Takes the field's text. A reason shown for the last refusal goes once you type.
    public func setDraft(_ text: String) {
        edit?.draft = text
        edit?.problem = nil
    }

    /// Esc: the title stays as it was.
    public func cancelEdit() { edit = nil }

    /// Return or Done: writes the new title through `AppState`. Only the title changes; the origin and status stay. An
    /// empty title is refused here, and a title the ledger refuses keeps the field and its text with the reason.
    @discardableResult
    public func saveEdit(through app: AppState) async -> Bool {
        guard let edit, !working.contains(edit.entry) else { return false }
        let id = edit.entry
        guard let title = edit.cleaned else {
            self.edit?.problem = TitleEdit.emptyTitle
            return false
        }
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].title != title else {
            self.edit = nil
            return true
        }
        working.insert(id)
        let written = await app.editEntry(id, title: title)
        working.remove(id)
        if written {
            if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].title = title }
            if self.edit?.entry == id { self.edit = nil }
            reload()
        } else if self.edit?.entry == id {
            self.edit?.problem = TitleEdit.refused(app.issue)
        }
        return written
    }

    // MARK: deciding

    /// Accepts a proposal. A title being edited on it is saved first, and a refused save accepts nothing.
    @discardableResult
    public func accept(_ id: String, through app: AppState) async -> Bool {
        if edit?.entry == id, !(await saveEdit(through: app)) { return false }
        return await decide(id, .accepted, through: app)
    }

    /// Dismisses a proposal, and with it any edit to its title.
    @discardableResult
    public func dismiss(_ id: String, through app: AppState) async -> Bool {
        if edit?.entry == id { edit = nil }
        return await decide(id, .dismissed, through: app)
    }

    /// Accepts every proposal shown, oldest first, and stops at the first the ledger refuses, so one failure is
    /// reported once. A title being edited is saved first. Returns how many were accepted.
    @discardableResult
    public func acceptAll(through app: AppState) async -> Int {
        if edit != nil, !(await saveEdit(through: app)) { return 0 }
        var accepted = 0
        for id in entries.reversed().map(\.id) {
            guard await decide(id, .accepted, through: app, reloading: false) else { break }
            accepted += 1
        }
        reload()
        return accepted
    }

    private func decide(_ id: String, _ status: EntryStatus, through app: AppState, reloading: Bool = true) async -> Bool {
        guard !working.contains(id) else { return false }
        working.insert(id)
        let written = await app.setStatus(id, to: status)
        working.remove(id)
        if written { entries.removeAll { $0.id == id } }
        if reloading { reload() }
        return written
    }
}
