import CadenceCore
import Dispatch
import Foundation
import Observation

/// The Log's state, published on the main actor (docs/SPEC.md section 4.6).
///
/// Every read runs on a background queue on a fresh read-only connection, so the main thread never waits on the disk.
/// Typing is debounced; a chip applies at once. Each read carries a generation, and a read that finishes after a newer
/// one was asked for is dropped, so the list always matches the filter shown.
@MainActor @Observable
public final class LogModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case loaded
        case failed(StoreFailure)
    }

    /// An entry opened in the detail panel, with its history as the ledger holds it.
    public struct Opened: Sendable, Equatable {
        public var entry: Entry
        public var events: [Event]
        /// Its place in its day, for discreet titles.
        public var index: Int

        public init(entry: Entry, events: [Event], index: Int) {
            self.entry = entry
            self.events = events
            self.index = index
        }
    }

    /// Typing waits this long for the next key before it searches.
    public static let debounce: Duration = .milliseconds(250)

    public private(set) var phase: Phase = .loading
    /// Newest first.
    public private(set) var entries: [Entry] = []
    public private(set) var today: LocalDate?
    public private(set) var zone: TimeZone = .current
    public private(set) var hasMore = false
    public private(set) var loadingMore = false
    /// The filter the list shows.
    public private(set) var filter = LogFilter()
    /// The text in the search field, ahead of the debounce.
    public private(set) var searchText = ""
    public private(set) var opened: Opened?
    /// The open entry's title as a field, while it is being edited.
    public private(set) var edit: TitleEdit?
    /// Why the last kind change was refused. Nil while there is nothing to say.
    public private(set) var kindProblem: String?
    /// A link being added to the open entry, while its field shows.
    public private(set) var linkEdit: LinkEdit?
    /// Why the last link could not be taken away. Nil while there is nothing to say.
    public private(set) var linkProblem: String?
    /// An edit to the open entry is being written, so its controls wait.
    public private(set) var saving = false
    /// Counts finished reads, so a caller can wait for the read after its change.
    public private(set) var reads = 0

    @ObservationIgnored private let reader: JournalReader
    @ObservationIgnored private let queue = DispatchQueue(label: "in.ashwingopalsamy.cadence.log-model", qos: .userInitiated)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var before: LocalDate?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// The entry asked for last; a slower read for another entry is dropped.
    @ObservationIgnored private var wanted: String?

    public init(location: StoreLocation, clock: any Clock) {
        reader = JournalReader(location: location, clock: clock)
    }

    // MARK: filters

    /// Takes the search field's text. The search runs once typing pauses.
    public func setSearch(_ text: String) {
        searchText = text
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            self.apply { $0.search = text }
        }
    }

    /// Picks one work kind, or none for All.
    public func setFamily(_ family: Family?) { apply { $0.family = family } }

    /// Picks one origin, or none for All.
    public func setOrigin(_ origin: Origin?) { apply { $0.origin = origin } }

    /// All: no kind and no origin. The search stays.
    public func clearChips() { apply { $0.family = nil; $0.origin = nil } }

    /// Clear filters: the search, the kind and the origin.
    public func clearFilters() {
        searchTask?.cancel()
        searchText = ""
        apply { $0 = LogFilter() }
    }

    private func apply(_ change: (inout LogFilter) -> Void) {
        var next = filter
        change(&next)
        guard next != filter else { return }
        filter = next
        reload()
    }

    // MARK: reading

    /// Reads the first page once, when the Log first shows.
    public func start() {
        guard !started else { return }
        reload()
    }

    /// Reads the first page again, for a new filter or a change to the store. An open entry is read again with it.
    public func reload() {
        started = true
        generation += 1
        let mine = generation
        let filter = filter
        let openID = opened?.entry.id
        loadingMore = false
        Task {
            let result = await reader.read(on: queue) { (journal) throws(CadenceError) -> LogPage in
                try LogPage.read(journal, filter: filter, before: nil)
            }
            guard mine == generation else { return }
            switch result {
            case .success(let page):
                entries = page.entries
                today = page.today
                zone = page.zone
                before = page.before
                hasMore = page.before != nil
                phase = .loaded
            case .failure(let failure) where failure.kind == .missing:
                // No store yet is an empty log, not a failure.
                entries = []
                hasMore = false
                phase = .loaded
            case .failure(let failure):
                entries = []
                hasMore = false
                phase = .failed(failure)
            }
            reads += 1
            if let openID { await readOpened(openID) }
        }
    }

    /// Reads the next older page, when the list scrolls to its end.
    public func loadMore() {
        guard hasMore, !loadingMore, let before, phase == .loaded else { return }
        loadingMore = true
        let mine = generation
        let filter = filter
        Task {
            let result = await reader.read(on: queue) { (journal) throws(CadenceError) -> LogPage in
                try LogPage.read(journal, filter: filter, before: before)
            }
            guard mine == generation else { return }
            loadingMore = false
            if case .success(let page) = result {
                entries += page.entries
                self.before = page.before
                hasMore = page.before != nil
            }
            reads += 1
        }
    }

    // MARK: the detail

    /// Opens an entry, or closes the detail with nil.
    public func open(_ id: String?) {
        if id != opened?.entry.id {
            edit = nil
            kindProblem = nil
            linkEdit = nil
            linkProblem = nil
        }
        wanted = id
        guard let id else {
            opened = nil
            return
        }
        Task { await readOpened(id) }
    }

    private func readOpened(_ id: String) async {
        let result = await reader.read(on: queue) { (journal) throws(CadenceError) -> (Entry, [Event]) in
            (try journal.entry(id), try journal.history(subject: "entry:\(id)"))
        }
        guard wanted == id else { return }
        guard case .success(let (entry, events)) = result, entry.status == .accepted else {
            opened = nil
            return
        }
        let index = entries.filter { $0.day == entry.day }.firstIndex { $0.id == id } ?? 0
        opened = Opened(entry: entry, events: events, index: index)
    }

    // MARK: editing the open entry

    /// Edit title: the open entry's title becomes a field holding its words.
    public func beginEdit() {
        guard let entry = opened?.entry else { return }
        kindProblem = nil
        edit = TitleEdit(entry: entry.id, draft: entry.title)
    }

    // MARK: links of the open entry

    /// Add link: a field for the address.
    public func beginAddLink() {
        guard let entry = opened?.entry else { return }
        linkProblem = nil
        linkEdit = LinkEdit(entry: entry.id, draft: "")
    }

    /// Takes the field's text. A reason shown for the last refusal goes once you type.
    public func setLinkDraft(_ text: String) {
        linkEdit?.draft = text
        linkEdit?.problem = nil
    }

    /// Esc: the entry stays as it was.
    public func cancelAddLink() { linkEdit = nil }

    /// Return or Add: writes the entry's links with the new one through `AppState`, which adds a version. Words that
    /// are not a web address are refused here; the rest is the ledger's rule, and its reason is shown beside the field.
    /// A link the entry already holds changes nothing.
    @discardableResult
    public func saveLink(through app: AppState) async -> Bool {
        guard let linkEdit, !saving else { return false }
        let id = linkEdit.entry
        guard let address = linkEdit.cleaned else {
            self.linkEdit?.problem = LinkEdit.empty
            return false
        }
        guard LinkEdit.looksWeb(address) else {
            self.linkEdit?.problem = LinkEdit.notWeb
            return false
        }
        guard let entry = opened?.entry, entry.id == id else {
            self.linkEdit = nil
            return false
        }
        let link = Link.inferred(url: address)
        guard !entry.links.contains(link) else {
            self.linkEdit = nil
            return true
        }
        saving = true
        let written = await app.editEntry(id, links: entry.links + [link])
        saving = false
        if written {
            if self.linkEdit?.entry == id { self.linkEdit = nil }
            reload()
        } else if self.linkEdit?.entry == id {
            self.linkEdit?.problem = LinkEdit.refused(app.issue)
            // The reason is beside the field, so a refusal of the rule is not a banner as well.
            if app.issue?.kind == .invalid { app.dismissIssue() }
        }
        return written
    }

    /// Takes one link off the open entry, as a new version through `AppState`.
    @discardableResult
    public func removeLink(_ link: Link, through app: AppState) async -> Bool {
        guard let entry = opened?.entry, !saving else { return false }
        guard entry.links.contains(link) else { return true }
        saving = true
        let written = await app.editEntry(entry.id, links: entry.links.filter { $0 != link })
        saving = false
        if written {
            linkProblem = nil
            reload()
        } else if opened?.entry.id == entry.id {
            linkProblem = LinkEdit.refused(app.issue)
        }
        return written
    }

    /// Takes the field's text. A reason shown for the last refusal goes once you type.
    public func setDraft(_ text: String) {
        edit?.draft = text
        edit?.problem = nil
    }

    /// Esc: the title stays as it was.
    public func cancelEdit() { edit = nil }

    /// Return or Done: writes the new title through `AppState`, which adds a version; nothing is overwritten. An empty
    /// title is refused here, and a title the ledger refuses keeps the field and its text with the reason.
    @discardableResult
    public func saveEdit(through app: AppState) async -> Bool {
        guard let edit, !saving else { return false }
        let id = edit.entry
        guard let title = edit.cleaned else {
            self.edit?.problem = TitleEdit.emptyTitle
            return false
        }
        guard opened?.entry.id == id, opened?.entry.title != title else {
            self.edit = nil
            return true
        }
        saving = true
        let written = await app.editEntry(id, title: title)
        saving = false
        if written {
            if self.edit?.entry == id { self.edit = nil }
            reload()
        } else if self.edit?.entry == id {
            self.edit?.problem = TitleEdit.refused(app.issue)
        }
        return written
    }

    /// Change kind: writes the open entry's new kind through `AppState`. Core moves its work kind with it, and the
    /// history gains a version.
    @discardableResult
    public func changeKind(_ kind: EntryKind, through app: AppState) async -> Bool {
        guard let entry = opened?.entry, !saving else { return false }
        guard kind != entry.kind else { return true }
        saving = true
        let written = await app.editEntry(entry.id, kind: kind)
        saving = false
        if written {
            kindProblem = nil
            reload()
        } else if opened?.entry.id == entry.id {
            kindProblem = TitleEdit.refusedKind(app.issue)
        }
        return written
    }
}
