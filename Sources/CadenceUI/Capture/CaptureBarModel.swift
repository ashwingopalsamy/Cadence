// What the capture bar holds between keystrokes (docs/SPEC.md sections 4.3 and 4.8). The field keeps the first
// responder the whole time; chips take a focus of their own, so Tab, ↩ and ⌫ act on the focused chip without the
// text field ever losing the caret.
import CadenceCore
import Foundation
import Observation

/// How a save went.
public enum CaptureSaveOutcome: Sendable, Equatable {
    case saved(Entry)
    case failed(StoreFailure)
}

@MainActor @Observable
public final class CaptureBarModel {
    /// What the bar asks of the app. Every closure is called on the main actor.
    public struct Environment {
        /// The parser's clock, zone and ticket rules, read when the bar opens.
        public var context: @MainActor () -> CaptureContext
        /// What collectors found today, for the duplicate offer.
        public var found: @MainActor () -> [Entry]
        /// Saves as self.
        public var save: @MainActor (LogRequest) async -> CaptureSaveOutcome
        /// The last entry you logged today, for `↑`.
        public var lastEntry: @MainActor () -> Entry?
        /// Takes back the entry `↑` brought into the bar, once its new version is saved.
        public var dismiss: @MainActor (Entry) async -> Bool
        /// Closes the bar.
        public var close: @MainActor () -> Void
        /// Whether discreet mode hides ticket keys.
        public var discreet: @MainActor () -> Bool

        public init(
            context: @escaping @MainActor () -> CaptureContext,
            found: @escaping @MainActor () -> [Entry] = { [] },
            save: @escaping @MainActor (LogRequest) async -> CaptureSaveOutcome,
            lastEntry: @escaping @MainActor () -> Entry? = { nil },
            dismiss: @escaping @MainActor (Entry) async -> Bool = { _ in false },
            close: @escaping @MainActor () -> Void = {},
            discreet: @escaping @MainActor () -> Bool = { false }
        ) {
            self.context = context
            self.found = found
            self.save = save
            self.lastEntry = lastEntry
            self.dismiss = dismiss
            self.close = close
            self.discreet = discreet
        }
    }

    /// How the bar was opened.
    public enum Mode: Sendable, Equatable {
        case capture
        /// `⌃⌥N`: the kind starts as note.
        case note
    }

    public var draft = CaptureDraft() {
        didSet {
            guard draft != oldValue else { return }
            if draft.text != oldValue.text {
                focusedChip = nil
                message = nil
            }
            if duplicateSignature != answeredDuplicate { answeredDuplicate = nil }
        }
    }
    /// The chip with keyboard focus; nil while the caret is in the field.
    public var focusedChip: Int?
    /// The chip being edited inline, and its text.
    public private(set) var editingChip: Int?
    public var editText = ""
    /// The line under the field: the empty-input message or a save that failed.
    public private(set) var message: Message?
    /// The entry `↑` brought back to edit.
    public private(set) var editingEntry: Entry?
    public private(set) var saving = false
    /// Bumped when the caret should return to the field.
    public private(set) var fieldFocusRequest = 0

    public enum Message: Sendable, Equatable {
        case empty
        case failed(StoreFailure)
    }

    @ObservationIgnored public var environment: Environment
    @ObservationIgnored private var context: CaptureContext
    /// The duplicate the person chose to log anyway, so the offer does not come back for the same line.
    private var answeredDuplicate: String?

    public init(environment: Environment) {
        self.environment = environment
        context = environment.context()
    }

    // MARK: Reading

    public var chips: [CaptureChip] {
        CaptureAdapter.chips(for: draft, context: context, discreet: environment.discreet())
    }

    /// The entry a collector already found that this line looks like, until the person answers the offer.
    public var duplicate: Entry? {
        guard answeredDuplicate == nil || answeredDuplicate != duplicateSignature else { return nil }
        return CaptureAdapter.duplicate(of: draft, in: environment.found(), context: context)
    }

    private var duplicateSignature: String? {
        CaptureAdapter.duplicate(of: draft, in: environment.found(), context: context)?.id
    }

    // MARK: Opening and closing

    /// Called each time the bar opens. A line whose save failed is kept, so nothing typed is lost.
    public func open(_ mode: Mode) {
        context = environment.context()
        if case .failed? = message {
            if mode == .note { draft.kind = .note }
        } else {
            draft = CaptureDraft(kind: mode == .note ? .note : nil)
            message = nil
            editingEntry = nil
        }
        focusedChip = nil
        editingChip = nil
        fieldFocusRequest += 1
    }

    /// Esc: an inline edit first, then the chip focus, then the bar.
    public func escape() {
        if editingChip != nil {
            editingChip = nil
            fieldFocusRequest += 1
        } else if focusedChip != nil {
            focusedChip = nil
        } else {
            environment.close()
        }
    }

    // MARK: Chips

    /// Tab and ⇧Tab: from the field into the chips and back.
    public func moveFocus(backward: Bool) {
        let count = chips.count
        guard count > 0 else { return }
        switch (focusedChip, backward) {
        case (nil, false): focusedChip = 0
        case (nil, true): focusedChip = count - 1
        case (let i?, false): focusedChip = i + 1 < count ? i + 1 : nil
        case (let i?, true): focusedChip = i > 0 ? i - 1 : nil
        }
    }

    /// A click, or ↩ on a focused chip: the kind cycles, any other chip opens for an inline edit.
    public func activate(_ index: Int) {
        let chips = self.chips
        guard chips.indices.contains(index) else { return }
        focusedChip = index
        let chip = chips[index]
        if chip.cycles {
            draft = CaptureAdapter.cyclingKind(draft, context: context)
            focusedChip = index
        } else {
            editText = CaptureAdapter.editableValue(chip, in: draft)
            editingChip = index
        }
    }

    /// ↩ in an inline edit. A value the parser does not read as that chip keeps the edit open.
    @discardableResult
    public func commitEdit() -> Bool {
        let chips = self.chips
        guard let index = editingChip, chips.indices.contains(index) else {
            editingChip = nil
            return false
        }
        guard let next = CaptureAdapter.editing(chips[index], to: editText, in: draft, context: context) else { return false }
        editingChip = nil
        draft = next
        fieldFocusRequest += 1
        return true
    }

    /// ⌫ on a focused chip removes it; ⌫ on an empty field removes the last chip. Returns whether it acted.
    @discardableResult
    public func deleteBackward(fieldIsEmpty: Bool) -> Bool {
        let chips = self.chips
        if let index = focusedChip, chips.indices.contains(index) {
            draft = CaptureAdapter.removing(chips[index], from: draft)
            let remaining = self.chips.count
            focusedChip = remaining == 0 ? nil : min(index, remaining - 1)
            return true
        }
        guard fieldIsEmpty, !chips.isEmpty else { return false }
        draft = CaptureAdapter.removingLast(from: draft, context: context)
        return true
    }

    /// ↑ on an empty field brings back the last entry you logged today, to change it.
    @discardableResult
    public func editLast() -> Bool {
        // In discreet mode a title is never put back on screen.
        guard draft.isBlank, !environment.discreet(), let entry = environment.lastEntry() else { return false }
        editingEntry = entry
        draft = CaptureDraft(text: Self.line(for: entry), kind: entry.kind)
        return true
    }

    // MARK: Saving

    /// ↩ saves and closes; ⌘↩ saves and keeps the bar open for the next line.
    public func submit(keepOpen: Bool) async {
        guard !saving else { return }
        if editingChip != nil {
            commitEdit()
            return
        }
        guard let request = CaptureAdapter.request(for: draft) else {
            message = .empty
            return
        }
        // The offer stands until it is answered; ↩ never logs a second copy past it.
        if duplicate != nil { return }
        saving = true
        defer { saving = false }
        switch await environment.save(request) {
        case .failed(let failure):
            message = .failed(failure)
        case .saved:
            if let old = editingEntry { _ = await environment.dismiss(old) }
            // A quick-note session stays a note session while it is kept open.
            reset(kind: keepOpen && draft.kind == .note ? .note : nil)
            if !keepOpen { environment.close() }
        }
    }

    /// "Link them": the found entry already counts, so nothing is written and the bar closes. The ledger has no link
    /// event, so linking is not logging a second copy.
    public func linkThem() {
        reset(kind: nil)
        environment.close()
    }

    /// "Log separately": logs the line as its own entry.
    public func logSeparately() async {
        answeredDuplicate = duplicateSignature
        await submit(keepOpen: false)
    }

    private func reset(kind: EntryKind?) {
        draft = CaptureDraft(kind: kind)
        message = nil
        editingEntry = nil
        focusedChip = nil
        editingChip = nil
        answeredDuplicate = nil
        fieldFocusRequest += 1
    }

    /// An entry as a line the parser reads back the same way: its title, then its time and duration.
    static func line(for entry: Entry) -> String {
        var parts = [entry.title]
        if let ticket = entry.ticket, !entry.title.contains(ticket.key) { parts.append(ticket.key) }
        if let at = entry.occurredAt, let clock = at.split(separator: "T").last?.prefix(5), clock.count == 5 {
            parts.append("@" + clock)
        }
        if let seconds = entry.durationS { parts.append("~" + CaptureAdapter.durationText(seconds).replacingOccurrences(of: " ", with: "")) }
        return parts.joined(separator: " ")
    }
}
