import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The capture bar (docs/SPEC.md sections 4.3 and 4.8): parity with Core's parser and the CLI, chips, the
/// duplicate offer, empty input, saving, and the global shortcuts.
@MainActor @Suite struct CaptureTests {
    typealias Home = DayStoreLoaderTests.Home
    static let zone = TimeZone(identifier: "Asia/Kolkata") ?? .gmt
    /// The same instant as the journal's clock in `Home`: Monday 21 Sep 2026, 19:03 in Kolkata.
    static let now = DayStoreLoaderTests.FixedClock().now()

    static func context() -> CaptureContext {
        CaptureAdapter.context(config: Config.defaults(timezone: "Asia/Kolkata"), now: now)
    }

    static func chips(_ text: String, kind: EntryKind? = nil) -> [CaptureChip] {
        CaptureAdapter.chips(for: CaptureDraft(text: text, kind: kind), context: context())
    }

    // MARK: Parity with Core

    /// The spec's examples (section 4.3) and the lines Core's own tests use.
    nonisolated static let examples = [
        "merged ACME-4821 retry fix @14:30",
        "raised retry storms in arch sync",
        "Fixed flaky ledger test with deterministic clock ACME-482913",
        "Reviewed settlement batching RFC",
        "Paired on the flaky ledger test",
        "Draft idempotency ADR",
        "Prototyped webhook replay tool ACME-000000",
        "Pair on flaky ledger test est~1h #quality",
        "Shipped retry budget for capture path (ACME-482913), PR #412 merged",
        "3 reviews",
        "attended 4 meetings for 1h30",
        "Led the incident review at 3pm ~2h",
        "Wrote the ADR yesterday 45m #docs",
        "Reviewed https://example.com/acme/api/pull/412 @10:30",
    ]

    @Test(arguments: examples)
    func chipsCarryWhatCoresParserFound(_ line: String) {
        let parsed = CaptureParser.parse(line, context: Self.context())
        let chips = Self.chips(line)
        #expect(chips.first?.role == .kind)
        #expect(chips.first?.value == CaptureAdapter.kindName(parsed.kind))
        #expect(chips.first?.family == EntryKind.family(for: parsed.kind, ticketClass: parsed.ticket?.class))
        #expect(chips.first { $0.role == .ticket }?.value == parsed.ticket?.key)
        let time = parsed.occurredAt.map { Timestamp.clockTime($0, in: Self.zone) }
        #expect(chips.first { $0.role == .time && $0.range != nil }?.value == time)
        #expect(chips.first { $0.role == .duration }?.value == parsed.durationS.map(CaptureAdapter.durationText))
        let count = chips.first { $0.role == .count }
        #expect((count == nil) == (parsed.quantity == 1))
        if let count { #expect(count.value.hasPrefix("\(parsed.quantity) ")) }
        #expect(chips.filter { $0.role == .tag }.map { String($0.value.dropFirst()).lowercased() } == parsed.tags)
    }

    @Test(arguments: examples)
    func theBarSavesWhatTheCLIWouldSave(_ line: String) throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let request = try #require(CaptureAdapter.request(for: CaptureDraft(text: line)))
        let bar = try journal.preview(request, origin: .selfReported)
        let cli = try journal.preview(LogRequest(text: line), origin: .selfReported)
        #expect(bar == cli)
    }

    @Test func aPickedKindTravelsToTheLedger() throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let request = try #require(CaptureAdapter.request(for: CaptureDraft(text: "merged ACME-4821 retry fix", kind: .note)))
        #expect(try journal.preview(request, origin: .selfReported).kind == .note)
    }

    @Test func ticketsSayAssignedOrSelfStarted() {
        #expect(Self.chips("Fixed ACME-4821")[1].detail == "assigned")
        #expect(Self.chips("Prototyped replay tool ACME-000000")[1].detail == "self-started")
        // A delivery kind on a self-started ticket wears the initiative colour.
        #expect(Self.chips("Merged ACME-000000")[0].family == .initiative)
    }

    @Test func aLineForTodayWithNoTimeReadsNow() {
        let now = Self.chips("Reviewed the RFC").last
        #expect(now?.role == .time)
        #expect(now?.value == "now")
        #expect(now?.range == nil)
        #expect(!Self.chips("Reviewed the RFC yesterday").contains { $0.role == .time })
        #expect(Self.chips("Reviewed the RFC yesterday").first { $0.role == .day }?.detail == "backfilled")
    }

    @Test func discreetModeHidesTicketKeys() {
        let chips = CaptureAdapter.chips(for: CaptureDraft(text: "Fixed ACME-4821"), context: Self.context(), discreet: true)
        #expect(!chips.contains { $0.value.contains("ACME") })
    }

    // MARK: Changing chips

    @Test func theKindChipCyclesThroughEveryKindAndWraps() {
        var draft = CaptureDraft(text: "merged ACME-4821 retry fix")
        var seen: [EntryKind] = []
        for _ in CaptureAdapter.kindCycle {
            draft = CaptureAdapter.cyclingKind(draft, context: Self.context())
            seen.append(draft.kind ?? .note)
        }
        #expect(seen.first == .shipped)
        #expect(Set(seen) == Set(CaptureAdapter.kindCycle))
        #expect(seen.last == .prMerged)
        #expect(CaptureAdapter.nextKind(after: .note) == .reviewGiven)
        #expect(CaptureAdapter.nextKind(after: .genaiUsage) == .reviewGiven)
    }

    @Test func removingAChipTakesItsWordsOutOfTheLine() throws {
        let draft = CaptureDraft(text: "merged ACME-4821 retry fix @14:30 ~45m #payments")
        let chips = CaptureAdapter.chips(for: draft, context: Self.context())
        let time = try #require(chips.first { $0.role == .time })
        #expect(CaptureAdapter.removing(time, from: draft).text == "merged ACME-4821 retry fix ~45m #payments")
        let tag = try #require(chips.first { $0.role == .tag })
        #expect(CaptureAdapter.removing(tag, from: draft).text == "merged ACME-4821 retry fix @14:30 ~45m")
    }

    @Test func removingTheKindChipFallsBackToNoteOrDropsAPickedKind() throws {
        let draft = CaptureDraft(text: "merged ACME-4821 retry fix")
        let kind = try #require(CaptureAdapter.chips(for: draft, context: Self.context()).first)
        #expect(CaptureAdapter.removing(kind, from: draft).kind == .note)
        let picked = CaptureDraft(text: "merged ACME-4821 retry fix", kind: .shipped)
        #expect(CaptureAdapter.removing(kind, from: picked).kind == nil)
    }

    @Test func backspaceOnAnEmptyFieldRemovesTheLastChip() {
        let model = Self.model()
        model.open(.note)
        #expect(model.chips.map(\.value) == ["Note"])
        #expect(model.deleteBackward(fieldIsEmpty: true))
        #expect(model.chips.isEmpty)
        #expect(!model.deleteBackward(fieldIsEmpty: true))
    }

    @Test func backspaceOnAFocusedChipRemovesIt() {
        let model = Self.model()
        model.draft.text = "merged ACME-4821 retry fix @14:30"
        model.moveFocus(backward: false)
        model.moveFocus(backward: false)
        #expect(model.chips[model.focusedChip ?? 0].role == .ticket)
        #expect(model.deleteBackward(fieldIsEmpty: false))
        #expect(model.draft.text == "merged retry fix @14:30")
    }

    @Test func tabAndShiftTabMoveBetweenChipsAndBackToTheField() {
        let model = Self.model()
        model.draft.text = "merged ACME-4821 retry fix @14:30"
        let count = model.chips.count
        #expect(count == 3)
        for index in 0..<count {
            model.moveFocus(backward: false)
            #expect(model.focusedChip == index)
        }
        model.moveFocus(backward: false)
        #expect(model.focusedChip == nil)
        model.moveFocus(backward: true)
        #expect(model.focusedChip == count - 1)
        model.draft.text += " "
        #expect(model.focusedChip == nil)
    }

    @Test func timeAndDurationEditInline() throws {
        let draft = CaptureDraft(text: "merged ACME-4821 retry fix @14:30 ~45m")
        let chips = CaptureAdapter.chips(for: draft, context: Self.context())
        let time = try #require(chips.first { $0.role == .time })
        #expect(CaptureAdapter.editableValue(time, in: draft) == "14:30")
        #expect(CaptureAdapter.editing(time, to: "15:10", in: draft, context: Self.context())?.text == "merged ACME-4821 retry fix @15:10 ~45m")
        #expect(CaptureAdapter.editing(time, to: "banana", in: draft, context: Self.context()) == nil)
        let duration = try #require(chips.first { $0.role == .duration })
        let longer = try #require(CaptureAdapter.editing(duration, to: "1h30", in: draft, context: Self.context()))
        #expect(CaptureParser.parse(longer.text, context: Self.context()).durationS == 5400)
        #expect(CaptureAdapter.editing(duration, to: "soon", in: draft, context: Self.context()) == nil)
    }

    @Test func editingTheNowChipAddsATime() throws {
        let draft = CaptureDraft(text: "Reviewed the RFC")
        let now = try #require(CaptureAdapter.chips(for: draft, context: Self.context()).last)
        let timed = try #require(CaptureAdapter.editing(now, to: "3pm", in: draft, context: Self.context()))
        #expect(timed.text == "Reviewed the RFC @3pm")
        let parsed = CaptureParser.parse(timed.text, context: Self.context())
        #expect(parsed.occurredAt.map { Timestamp.clockTime($0, in: Self.zone) } == "15:00")
    }

    @Test func aClickOnTheKindCyclesAndOnATimeOpensAnEdit() {
        let model = Self.model()
        model.draft.text = "merged ACME-4821 retry fix @14:30"
        model.activate(0)
        #expect(model.draft.kind == .shipped)
        #expect(model.editingChip == nil)
        model.activate(2)
        #expect(model.editingChip == 2)
        #expect(model.editText == "14:30")
        model.editText = "nonsense"
        #expect(!model.commitEdit())
        #expect(model.editingChip == 2)
        model.editText = "09:15"
        #expect(model.commitEdit())
        #expect(model.draft.text == "merged ACME-4821 retry fix @09:15")
    }

    // MARK: The duplicate offer

    static func found(kind: EntryKind = .prMerged, day: String = "2026-09-21", origin: Origin = .collected) -> Entry {
        Entry(
            id: "01JBACME000000000000000001", day: day, kind: kind, family: kind.defaultFamily,
            title: "Retry fix for the capture path", ticket: Ticket(key: "ACME-4821", class: .assigned), origin: origin,
            source: "github")
    }

    @Test func aMergeGitHubAlreadyFoundIsOffered() throws {
        let draft = CaptureDraft(text: "merged ACME-4821 retry fix @14:30")
        let entry = try #require(CaptureAdapter.duplicate(of: draft, in: [Self.found()], context: Self.context()))
        #expect(CaptureAdapter.duplicateMessage(entry) == "Looks like the same merge GitHub already found.")
    }

    @Test func onlySameTicketSameKindSameDayFromACollectorIsADuplicate() {
        let context = Self.context()
        let line = CaptureDraft(text: "merged ACME-4821 retry fix")
        #expect(CaptureAdapter.duplicate(of: line, in: [Self.found(kind: .reviewGiven)], context: context) == nil)
        #expect(CaptureAdapter.duplicate(of: line, in: [Self.found(day: "2026-09-20")], context: context) == nil)
        #expect(CaptureAdapter.duplicate(of: line, in: [Self.found(origin: .selfReported)], context: context) == nil)
        #expect(CaptureAdapter.duplicate(of: CaptureDraft(text: "merged ACME-4822 fix"), in: [Self.found()], context: context) == nil)
        #expect(CaptureAdapter.duplicate(of: CaptureDraft(text: "merged retry fix"), in: [Self.found()], context: context) == nil)
        // A kind picked on the chip counts, not the word typed.
        #expect(CaptureAdapter.duplicate(of: CaptureDraft(text: "merged ACME-4821", kind: .note), in: [Self.found()], context: context) == nil)
        #expect(CaptureAdapter.duplicate(of: CaptureDraft(text: "merged ACME-4821 yesterday"), in: [Self.found(day: "2026-09-20")], context: context) != nil)
    }

    @Test func linkThemWritesNothingAndLogSeparatelyLogs() async {
        let recorder = Recorder()
        let model = Self.model(recorder: recorder, found: [Self.found()])
        model.open(.capture)
        model.draft.text = "merged ACME-4821 retry fix"
        #expect(model.duplicate != nil)
        await model.submit(keepOpen: false)
        #expect(recorder.saved.isEmpty)
        model.linkThem()
        #expect(recorder.saved.isEmpty)
        #expect(recorder.closed == 1)
        #expect(model.draft.isBlank)

        model.draft.text = "merged ACME-4821 retry fix"
        await model.logSeparately()
        #expect(recorder.saved.map(\.text) == ["merged ACME-4821 retry fix"])
        #expect(recorder.closed == 2)
    }

    // MARK: Saving

    @Test func emptyInputAsksForAFewWords() async {
        let recorder = Recorder()
        let model = Self.model(recorder: recorder)
        model.draft.text = "   "
        await model.submit(keepOpen: false)
        #expect(model.message == .empty)
        #expect(recorder.saved.isEmpty)
        #expect(CaptureAdapter.emptyMessage == "Write a few words first, and I will work out the rest.")
        model.draft.text = "R"
        #expect(model.message == nil)
    }

    @Test func returnSavesAsSelfAndCloses() async {
        let recorder = Recorder()
        let model = Self.model(recorder: recorder)
        model.draft.text = "  Reviewed the RFC  "
        await model.submit(keepOpen: false)
        #expect(recorder.saved.map(\.text) == ["Reviewed the RFC"])
        #expect(recorder.closed == 1)
        #expect(model.draft.isBlank)
    }

    @Test func commandReturnSavesAndKeepsTheBarOpen() async {
        let recorder = Recorder()
        let model = Self.model(recorder: recorder)
        model.open(.note)
        model.draft.text = "Ideas for the retry budget"
        await model.submit(keepOpen: true)
        #expect(recorder.saved.first?.kind == .note)
        #expect(recorder.closed == 0)
        #expect(model.draft == CaptureDraft(kind: .note))
    }

    @Test func aFailedSaveKeepsTheLineAndSaysWhy() async {
        let recorder = Recorder()
        recorder.failure = StoreFailure(kind: .busy, summary: "Cadence could not save that", detail: "The store is busy.")
        let model = Self.model(recorder: recorder)
        model.open(.capture)
        model.draft.text = "Reviewed the RFC"
        await model.submit(keepOpen: false)
        #expect(recorder.closed == 0)
        #expect(model.message == .failed(recorder.failure!))
        model.open(.capture)
        #expect(model.draft.text == "Reviewed the RFC")
    }

    @Test func upBringsBackTheLastEntryAndSavingReplacesIt() async {
        let recorder = Recorder()
        let last = Entry(
            id: "01JBACME000000000000000002", day: "2026-09-21", kind: .reviewGiven, family: .review,
            title: "Reviewed the RFC", occurredAt: "2026-09-21T14:30:00+05:30", durationS: 2700, origin: .selfReported)
        let model = Self.model(recorder: recorder, last: last)
        model.open(.capture)
        #expect(model.editLast())
        #expect(model.draft.text == "Reviewed the RFC @14:30 ~45m")
        model.draft.text = "Reviewed the RFC with ACME-4821 @14:30 ~45m"
        await model.submit(keepOpen: false)
        #expect(recorder.saved.count == 1)
        #expect(recorder.dismissed == [last.id])
        model.draft.text = "x"
        #expect(!model.editLast())
    }

    @Test func escapeLeavesAnEditThenAChipThenTheBar() {
        let recorder = Recorder()
        let model = Self.model(recorder: recorder)
        model.draft.text = "merged ACME-4821 @14:30"
        model.activate(2)
        model.escape()
        #expect(model.editingChip == nil)
        #expect(model.focusedChip == 2)
        model.escape()
        #expect(model.focusedChip == nil)
        #expect(recorder.closed == 0)
        model.escape()
        #expect(recorder.closed == 1)
    }

    @MainActor final class Recorder {
        var saved: [LogRequest] = []
        var closed = 0
        var dismissed: [String] = []
        var failure: StoreFailure?
    }

    static func model(recorder: Recorder = Recorder(), found: [Entry] = [], last: Entry? = nil) -> CaptureBarModel {
        CaptureBarModel(
            environment: CaptureBarModel.Environment(
                context: { context() },
                found: { found },
                save: { request in
                    if let failure = recorder.failure { return .failed(failure) }
                    recorder.saved.append(request)
                    return .saved(Entry(id: "01JBACME000000000000000003", day: "2026-09-21", kind: request.kind ?? .note, family: .presence, title: request.text, origin: .selfReported))
                },
                lastEntry: { last },
                dismiss: { entry in
                    recorder.dismissed.append(entry.id)
                    return true
                },
                close: { recorder.closed += 1 }))
    }

    // MARK: Hotkeys

    @MainActor final class FakeRegistrar: HotkeyRegistrar {
        var taken: Set<String> = []
        var registered: [UInt32: HotkeyBinding] = [:]
        var unregistered: [UInt32] = []

        func register(_ binding: HotkeyBinding, id: UInt32) -> Int32 {
            // -9878 is eventHotKeyExistsErr.
            if taken.contains(binding.display) { return -9878 }
            registered[id] = binding
            return 0
        }

        func unregister(id: UInt32) {
            unregistered.append(id)
            registered[id] = nil
        }
    }

    @Test func theStandardShortcuts() {
        let standard = HotkeyBindings.standard
        #expect(standard.all.map(\.display) == ["⌃⌥L", "⌃⌥N", "⌃⌥D"])
        #expect(standard.all.map(\.action) == [.capture, .quickNote, .discreet])
        #expect(standard.all.map(\.keyCode) == [37, 45, 2])
    }

    @Test func everyShortcutRegistersAndAPressFindsItsAction() {
        let registrar = FakeRegistrar()
        let center = HotkeyCenter(registrar: registrar)
        #expect(center.apply(.standard).isEmpty)
        #expect(registrar.registered.count == 3)
        for (id, binding) in registrar.registered {
            #expect(center.action(for: id) == binding.action)
        }
        #expect(center.action(for: 99) == nil)
    }

    @Test func aClashIsReportedAndTheOthersStillWork() {
        let registrar = FakeRegistrar()
        registrar.taken = ["⌃⌥L"]
        let center = HotkeyCenter(registrar: registrar)
        let clashes = center.apply(.standard)
        #expect(clashes.count == 1)
        #expect(clashes.first?.status == -9878)
        #expect(clashes.first?.message == "⌃⌥L is already used by another app. Pick another shortcut, or use the menu-bar icon.")
        #expect(center.clashes == clashes)
        #expect(Set(registrar.registered.values.map(\.action)) == [.quickNote, .discreet])
    }

    @Test func newBindingsReplaceTheOldOnes() {
        let registrar = FakeRegistrar()
        let center = HotkeyCenter(registrar: registrar)
        center.apply(.standard)
        var changed = HotkeyBindings.standard
        changed.capture = HotkeyBinding(action: .capture, keyCode: 40, key: "K", modifiers: [.control, .option, .shift])
        #expect(center.apply(changed).isEmpty)
        #expect(registrar.unregistered.count == 3)
        #expect(registrar.registered.values.contains { $0.display == "⌃⌥⇧K" })
        #expect(center.bindings == changed)
    }
}
