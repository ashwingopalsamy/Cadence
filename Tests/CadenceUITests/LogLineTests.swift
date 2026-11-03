import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// What a log field says a typed line will save as, and how a link is named and opened (docs/PLAN.md T4.17).
@MainActor @Suite struct LogLineTests {
    static let pr = "https://git.example.com/acme/api/pull/88"

    static func context() -> CaptureContext {
        CaptureAdapter.context(zone: TimeZone(identifier: "Asia/Kolkata") ?? .gmt, boundary: .standard, now: Date(timeIntervalSince1970: 1_790_000_000))
    }

    static func line(_ text: String, picked: EntryKind? = nil, discreet: Bool = false) -> LogLine {
        LogLine(text: text, picked: picked, context: context(), discreet: discreet)
    }

    // MARK: the kind it will save as

    @Test func aReviewPhraseIsShownAsReview() {
        for text in ["Code review of the retry fix", "PR review for ACME-482913", "Reviewing the settlement doc", "Reviewed the RFC"] {
            let line = Self.line(text)
            #expect(line.kind == .reviewGiven, "\(text)")
            #expect(line.kindName == "Review")
            #expect(line.matched && !line.picked)
        }
        #expect(Self.line("Opened a PR for the retry fix").kindName == "PR opened")
        #expect(Self.line("Merged the retry fix").kindName == "PR merged")
    }

    @Test func aMissIsShownAsNoteSoThePersonSeesIt() {
        for text in ["Quick review", "Went through the retry fix", "Did a thing"] {
            let line = Self.line(text)
            #expect(line.kind == .note, "\(text)")
            #expect(line.kindName == "Note")
            #expect(!line.matched)
        }
    }

    @Test func aPickedKindWinsAndSaysSo() {
        let line = Self.line("Went through the retry fix", picked: .reviewGiven)
        #expect(line.kind == .reviewGiven && line.kindName == "Review" && line.picked)
        #expect(line.family == .review)
        // The pick wins over what the words say.
        #expect(Self.line("Reviewed the RFC", picked: .note).kindName == "Note")
        // A delivery kind on a self-started ticket is initiative work, as it is when saved.
        #expect(Self.line("Shipped the replay tool ACME-000000", picked: .shipped).family == .initiative)
    }

    @Test func theChipSpeaksItsKindAndItsAction() {
        #expect(Self.line("Reviewed the RFC").kindVoice == "Kind, Review. Change kind")
        #expect(Self.line("Did a thing").kindVoice == "Kind, Note. Change kind")
        #expect(Self.line("Did a thing", picked: .mentoring).kindVoice == "Kind, Mentoring. Change kind")
    }

    @Test func theMenuOffersTheKindsAPersonLogsUnderTheirWorkKind() {
        let kinds = TitleEdit.kindsByFamily.flatMap(\.kinds)
        #expect(kinds.contains(.reviewGiven) && kinds.contains(.prOpened) && kinds.contains(.note))
        #expect(!kinds.contains(.presenceSpan) && !kinds.contains(.genaiSession) && !kinds.contains(.genaiUsage))
        #expect(EntryWords.family(.review) == "Review")
        // Every offered kind has a name for the chip, and none is named twice.
        let names = kinds.map(CaptureAdapter.kindName)
        #expect(Set(names).count == names.count)
    }

    // MARK: links

    @Test func aLinkInTheLineIsNamedForItsChip() {
        let line = Self.line("Reviewed \(Self.pr)")
        #expect(line.links == [Link(kind: .pr, url: Self.pr)])
        #expect(line.linkChip == "PR #88")
        #expect(line.linkVoice == "Link, PR #88")
        let two = Self.line("Reviewed \(Self.pr) and https://docs.example.com/retry")
        #expect(two.linkChip == "PR #88 +1")
        #expect(Self.line("Reviewed the RFC").linkChip == nil)
        #expect(Self.line("Reviewed the RFC").linkVoice == nil)
    }

    @Test func aLineThatIsOnlyALinkIsAMissAsAKindButHasItsLink() {
        let line = Self.line(Self.pr)
        #expect(line.kindName == "Note")
        #expect(line.linkChip == "PR #88")
    }

    @Test func theChipsHideNamesInDiscreetMode() {
        let line = Self.line("Reviewed \(Self.pr)", discreet: true)
        #expect(line.linkChip == "Link")
        #expect(line.linkVoice == "Link")
    }

    // MARK: opening a link

    @Test func aLinkTargetIsNamedAndOpensOnlyAWebAddress() throws {
        let target = LinkTarget(Link(kind: .pr, url: Self.pr))
        #expect(target.name == "PR #88")
        #expect(target.url == URL(string: Self.pr))
        #expect(target.openVoice == "Open PR #88")
        #expect(LinkTarget(Link(kind: .ticket, url: "https://tickets.example.com/browse/ACME-12")).name == "ACME-12")
        #expect(LinkTarget(Link(kind: .other, url: "https://docs.example.com/page")).name == "docs.example.com")
        // Whatever the ledger holds, only http and https are ever handed to the system to open.
        #expect(LinkTarget(Link(kind: .other, url: "file:///etc/passwd")).url == nil)
        #expect(LinkTarget(Link(kind: .other, url: "javascript:alert(1)")).url == nil)
        #expect(LinkTarget(Link(kind: .other, url: "not a url")).url == nil)
    }

    @Test func discreetModeNamesLinksByPlaceNotByAddress() {
        let first = LinkTarget(Link(kind: .pr, url: Self.pr), discreet: true, index: 0)
        let second = LinkTarget(Link(kind: .other, url: "https://docs.example.com/x"), discreet: true, index: 1)
        #expect(first.name == "Link 1" && second.name == "Link 2")
        #expect(first.openVoice == "Open Link 1")
        #expect(first.url == URL(string: Self.pr), "the address still opens; only the words are hidden")
        #expect(first.help == nil)
        #expect(LinkTarget(Link(kind: .pr, url: Self.pr)).help == Self.pr)
    }

    // MARK: the parser context

    @Test func theLiveContextReadsTheDaysZoneAndBoundary() async throws {
        let home = DayStoreLoaderTests.Home()
        defer { home.remove() }
        let app = try await AppStateTests.make(home)
        let context = app.captureContext
        #expect(context.zone.identifier == "Asia/Kolkata")
        #expect(context.boundary == DayBoundary.standard)
        let line = LogLine(text: "Code review of the retry fix", picked: nil, context: context, discreet: false)
        #expect(line.kind == .reviewGiven)
    }
}
