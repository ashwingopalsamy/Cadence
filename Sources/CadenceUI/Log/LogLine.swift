// What a log field says about the line being typed (docs/SPEC.md sections 4.3 and 4.6): the kind it will save as and the
// links in it, read live by Core's `CaptureParser`, the parser `cadence log` and the journal run, so the field and the
// entry never disagree. A line that matches no kind saves as a note, and the field says "Note" so a miss is seen.
import CadenceCore
import Foundation

/// The kind and links a typed line will save with.
public struct LogLine: Sendable, Equatable {
    /// The kind it saves as: the one the person picked, else the one the words say, else note.
    public let kind: EntryKind
    public let family: Family
    /// The person picked the kind on the chip.
    public let picked: Bool
    /// The words named a kind (a lexicon word or a counted noun). False is the note a line falls back to.
    public let matched: Bool
    /// The https links in the line, which leave the title and are saved with the entry.
    public let links: [Link]
    let discreet: Bool

    public init(text: String, picked: EntryKind?, context: CaptureContext, discreet: Bool) {
        let parsed = CaptureParser.parse(text, context: context)
        kind = picked ?? parsed.kind
        family = EntryKind.family(for: kind, ticketClass: parsed.ticket?.class)
        self.picked = picked != nil
        matched = parsed.kindMatched
        links = parsed.links
        self.discreet = discreet
    }

    /// The kind's name on the chip: "Review", "PR opened", "Note".
    public var kindName: String { CaptureAdapter.kindName(kind) }

    /// "Kind, Review. Change kind".
    public var kindVoice: String { String(localized: "Kind, \(kindName). Change kind") }

    /// The first link's name, with how many more there are: "PR #88", "PR #88 +1". Nil without a link. In discreet
    /// mode only the word "Link" is shown.
    public var linkChip: String? {
        guard let first = links.first else { return nil }
        let name = discreet ? String(localized: "Link") : first.displayName
        return links.count > 1 ? "\(name) +\(links.count - 1)" : name
    }

    /// What VoiceOver says for the link chip.
    public var linkVoice: String? {
        guard let chip = linkChip else { return nil }
        return discreet ? chip : String(localized: "Link, \(chip)")
    }

    /// "Automatic" in the kind menu takes a picked kind back.
    public static let automatic = String(localized: "Automatic")
}

/// A link as a surface shows it (docs/SPEC.md section 4.6): its name and the address the system opens. Cadence has no
/// network code: opening hands the address to the default browser.
public struct LinkTarget: Sendable, Equatable, Identifiable {
    public let link: Link
    public let name: String
    /// Set only for an http or https address; anything else the ledger might hold is shown but never opened.
    public let url: URL?
    let discreet: Bool

    public var id: String { link.url }

    /// `index` numbers the links of an entry in discreet mode, where a link is "Link 1", never its address.
    public init(_ link: Link, discreet: Bool = false, index: Int = 0) {
        self.link = link
        self.discreet = discreet
        name = discreet ? String(localized: "Link \(index + 1)") : link.displayName
        if let url = URL(string: link.url), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil {
            self.url = url
        } else {
            self.url = nil
        }
    }

    /// "Open PR #88".
    public var openVoice: String { String(localized: "Open \(name)") }

    /// The address, as a tooltip. Hidden in discreet mode.
    public var help: String? { discreet ? nil : link.url }
}

extension Entry {
    /// The entry's links as a surface shows them.
    func linkTargets(discreet: Bool) -> [LinkTarget] {
        links.enumerated().map { LinkTarget($1, discreet: discreet, index: $0) }
    }
}

extension AppState {
    /// The parser's context for a field that reads the line as it is typed: the day's zone and boundary as the store
    /// reported them, the standard ticket rules. The kind and links a line shows do not depend on ticket rules, and the
    /// journal parses the saved line again with the real config.
    public var captureContext: CaptureContext {
        let zone = context.flatMap { TimeZone(identifier: $0.zone) } ?? .current
        let boundary = context.flatMap { DayBoundary(hour: $0.boundaryMinutes / 60, minute: $0.boundaryMinutes % 60) } ?? .standard
        return CaptureAdapter.context(zone: zone, boundary: boundary, now: now)
    }
}
