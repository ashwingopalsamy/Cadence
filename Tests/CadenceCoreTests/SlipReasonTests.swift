import Foundation
import Testing

@testable import CadenceCore

/// The wrap-up's reason chips (docs/SPEC.md section 4.5). The ledger keeps any reason text; the chips are a fixed list
/// over it, so a stored reason either is a chip or is free text.
@Suite struct SlipReasonTests {
    typealias F = DayMechanicsTests.Fixture

    @Test func theChipsAreTheSpecsFourInOrderWithStableRawValues() {
        #expect(SlipReason.allCases == [.reprioritised, .blocked, .tooBig, .waitingOnSomeone])
        // The first two are the strings the ledger, the demo seed and the CLI examples already store.
        #expect(SlipReason.reprioritised.rawValue == "reprioritised")
        #expect(SlipReason.blocked.rawValue == "blocked")
        #expect(SlipReason.tooBig.rawValue == "too_big")
        #expect(SlipReason.waitingOnSomeone.rawValue == "waiting_on_someone")
        #expect(Set(SlipReason.allCases.map(\.rawValue)).count == 4)
    }

    @Test func labelsAreSentenceCaseExactlyAsTheChipsRead() {
        #expect(SlipReason.allCases.map(\.label) == ["Reprioritised", "Blocked", "Too big", "Waiting on someone"])
    }

    @Test func aStoredReasonRoundTripsToItsChip() throws {
        for reason in SlipReason.allCases {
            #expect(SlipReason(stored: reason.rawValue) == reason)
            #expect(SlipReason(rawValue: reason.rawValue) == reason)
        }
        let encoded = try JSONEncoder().encode(SlipReason.allCases)
        #expect(String(decoding: encoded, as: UTF8.self) == #"["reprioritised","blocked","too_big","waiting_on_someone"]"#)
        #expect(try JSONDecoder().decode([SlipReason].self, from: encoded) == SlipReason.allCases)
    }

    @Test func freeTextIsNotAChip() {
        for text in [
            "", " ", "stuck in review", "Blocked", "BLOCKED", " blocked", "blocked ", "too big", "tooBig",
            "waiting on someone", "reprioritized", "blocked by ACME-482913",
        ] {
            #expect(SlipReason(stored: text) == nil, "\(text)")
        }
    }

    @Test func theLedgerStillTakesAnyReasonAndFreeTextStillResolvesATask() throws {
        let f = try F()
        let free = try f.plan("Draft the ADR", on: "2026-10-29")
        let resolved = try f.journal.planResolve(
            taskID: free.id, status: .slipped, reason: "stuck in review", note: nil, links: [], actor: .cli)
        #expect(resolved.status == .slipped && resolved.reason == "stuck in review")
        #expect(resolved.reason.flatMap(SlipReason.init(stored:)) == nil)

        // A chip is stored as its raw value and read back as the chip.
        for reason in SlipReason.allCases {
            let task = try f.plan("Task for \(reason.label)", on: "2026-10-29")
            let slipped = try f.journal.planResolve(
                taskID: task.id, status: .slipped, reason: reason.rawValue, note: nil, links: [], actor: .app)
            #expect(slipped.reason == reason.rawValue)
            #expect(try f.journal.task(task.id).reason.flatMap(SlipReason.init(stored:)) == reason)
        }
        // A slip still needs some reason, chip or not.
        let bare = try f.plan("No reason", on: "2026-10-29")
        #expect(throws: CadenceError.self) {
            try f.journal.planResolve(taskID: bare.id, status: .slipped, reason: nil, note: nil, links: [], actor: .app)
        }
    }

    @Test func theEventPayloadAndTheSummaryKeysAreTheStoredStrings() throws {
        let f = try F()
        let reasons = SlipReason.allCases.map(\.rawValue) + ["stuck in review"]
        var tasks: [PlanTask] = []
        for reason in reasons {
            let task = try f.plan("Task \(reason)", on: "2026-10-29")
            tasks.append(task)
            _ = try f.journal.planResolve(taskID: task.id, status: .slipped, reason: reason, note: nil, links: [], actor: .cli)
        }
        for (task, reason) in zip(tasks, reasons) {
            let resolved = try #require(
                try f.store.events(subject: "task:\(task.id)").last { $0.type == "plan.resolved" })
            #expect(resolved.data.objectValue?["reason"]?.stringValue == reason)
        }
        _ = try f.seal("2026-10-29")
        let summary = try f.journal.summary(from: f.day("2026-10-29"), to: f.day("2026-10-29"))
        #expect(summary.slipsByReason == Dictionary(uniqueKeysWithValues: reasons.map { ($0, 1) }))
    }
}
