// The capture bar's reading of a line (docs/SPEC.md section 4.3). Pure: every chip comes from Core's
// `CaptureParser`, the same parser `cadence log` runs, so the bar and the CLI never disagree. The only thing the bar
// adds is a kind you picked by clicking the kind chip, which travels to the ledger as `LogRequest.kind`.
import CadenceCore
import Foundation

/// One chip under the capture field.
public struct CaptureChip: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, Equatable {
        case kind, ticket, link, time, day, duration, count, tag
    }

    public var role: Role
    /// The small word before the value ("kind", "ticket").
    public var label: String
    /// What the chip shows.
    public var value: String
    /// A quiet note after the value: "assigned", "self-started", "backfilled".
    public var detail: String?
    /// The work colour, for kind chips only. The kind's name is always beside it.
    public var family: Family?
    /// Where the chip's token sits in the line. Nil for the kind chip and for a time chip that reads "now".
    public var range: Range<String.Index>?
    /// Shown in the figure face: tickets and times (section 6.3).
    public var isFigure: Bool
    /// The chip's place in the row.
    public var order = 0

    public var id: String { "\(order)-\(role.rawValue)-\(value)" }

    /// The kind chip cycles; every other chip edits inline.
    public var cycles: Bool { role == .kind }
}

/// The line and the one choice made outside it.
public struct CaptureDraft: Sendable, Equatable {
    public var text: String
    /// A kind picked on the kind chip, or set by the quick-note hotkey. Nil lets the parser decide.
    public var kind: EntryKind?

    public init(text: String = "", kind: EntryKind? = nil) {
        self.text = text
        self.kind = kind
    }

    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum CaptureAdapter {
    // MARK: Copy (section 4.3, prototype `captureBar`)

    public static let placeholder = String(localized: "What did you do? Try: merged ACME-4821 retry fix @14:30")
    public static let emptyMessage = String(localized: "Write a few words first, and I will work out the rest.")
    public static let hint = String(localized: "Tab moves between chips. Click a chip to change it. Saved as logged by you.")
    public static let chipsHint = String(localized: "Kinds, tickets and times turn into chips as you type.")
    public static let linkThem = String(localized: "Link them")
    public static let logSeparately = String(localized: "Log separately")
    public static let linkReason = String(localized: "Link them and it counts once.")

    // MARK: Parsing

    /// The parser's context from the store's config, read the way `Journal` reads it, so the bar and `cadence log`
    /// see the same zone, day boundary and ticket rules. Rules that do not compile fall back to the standard ones,
    /// as a config the CLI refuses never reaches the ledger anyway.
    public static func context(config: Config, now: Date) -> CaptureContext {
        let zone = TimeZone(identifier: config.profile.timezone) ?? .current
        let classifier = (try? TicketClassifier(rules: config.tickets)) ?? standardClassifier
        return CaptureContext(now: now, zone: zone, boundary: config.dayBoundary, classifier: classifier)
    }

    // The standard rules are a constant that Core's tests compile.
    private static let standardClassifier = try! TicketClassifier(rules: .standard)

    public static func parse(_ draft: CaptureDraft, context: CaptureContext) -> ParsedCapture {
        CaptureParser.parse(draft.text, context: context)
    }

    /// The kind that will be saved.
    public static func kind(of draft: CaptureDraft, context: CaptureContext) -> EntryKind {
        draft.kind ?? parse(draft, context: context).kind
    }

    /// What the bar saves. Core parses the text again with the same rules, so the entry matches the chips.
    /// Nil for a blank line.
    public static func request(for draft: CaptureDraft) -> LogRequest? {
        guard !draft.isBlank else { return nil }
        return LogRequest(text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines), kind: draft.kind)
    }

    /// The chips for a draft: the kind first, then every token in the order it appears, then "now" when the line
    /// names no time and is for today. A blank line shows only a kind you picked.
    public static func chips(for draft: CaptureDraft, context: CaptureContext, discreet: Bool = false) -> [CaptureChip] {
        if draft.isBlank {
            guard let kind = draft.kind else { return [] }
            return [kindChip(kind, ticketClass: nil)]
        }
        let parsed = parse(draft, context: context)
        let today = context.boundary.day(of: context.now, in: context.zone)
        var chips = [kindChip(draft.kind ?? parsed.kind, ticketClass: parsed.ticket?.class)]
        var sawTime = false
        for found in parsed.tokens {
            let token = trimmed(found, in: draft.text)
            switch token.kind {
            case .kind:
                continue
            case .ticket:
                let selfStarted = parsed.ticket?.class == .selfInitiated
                chips.append(
                    CaptureChip(
                        role: .ticket, label: String(localized: "ticket"), value: discreet ? String(localized: "hidden") : token.text,
                        detail: selfStarted ? String(localized: "self-started") : String(localized: "assigned"), range: token.range, isFigure: !discreet))
            case .link:
                chips.append(
                    CaptureChip(
                        role: .link, label: String(localized: "link"), value: discreet ? String(localized: "hidden") : linkName(token.text), range: token.range,
                        isFigure: false))
            case .time:
                sawTime = true
                let value = parsed.occurredAt.map { Timestamp.clockTime($0, in: context.zone) } ?? token.text
                chips.append(CaptureChip(role: .time, label: String(localized: "time"), value: value, range: token.range, isFigure: true))
            case .day:
                chips.append(
                    CaptureChip(
                        role: .day, label: String(localized: "day"), value: token.text, detail: parsed.backfilled ? String(localized: "backfilled") : nil,
                        range: token.range, isFigure: false))
            case .duration:
                let value = parsed.durationS.map(durationText) ?? token.text
                chips.append(CaptureChip(role: .duration, label: String(localized: "duration"), value: value, range: token.range, isFigure: false))
            case .count:
                chips.append(CaptureChip(role: .count, label: String(localized: "count"), value: token.text, range: token.range, isFigure: false))
            case .tag:
                chips.append(CaptureChip(role: .tag, label: String(localized: "tag"), value: token.text, range: token.range, isFigure: false))
            }
        }
        if !sawTime, parsed.day == today {
            chips.append(CaptureChip(role: .time, label: String(localized: "time"), value: String(localized: "now"), range: nil, isFigure: false))
        }
        for index in chips.indices { chips[index].order = index }
        return chips
    }

    // MARK: Changing chips

    /// The kinds the kind chip steps through, in the order of the lexicon (section 4.3), then note.
    public static let kindCycle: [EntryKind] = [
        .reviewGiven, .prMerged, .shipped, .workDone, .discussionRaised, .decisionChallenged, .meetingLed,
        .meetingAttended, .mentoring, .incidentHandled, .initiativeStarted, .docWritten, .note,
    ]

    public static func nextKind(after kind: EntryKind) -> EntryKind {
        guard let index = kindCycle.firstIndex(of: kind) else { return kindCycle[0] }
        return kindCycle[(index + 1) % kindCycle.count]
    }

    /// Clicking the kind chip: the next kind in the cycle, held as the draft's kind.
    public static func cyclingKind(_ draft: CaptureDraft, context: CaptureContext) -> CaptureDraft {
        var next = draft
        next.kind = nextKind(after: kind(of: draft, context: context))
        return next
    }

    /// Removes a chip. A token chip takes its words out of the line; the kind chip drops a picked kind, or, when the
    /// parser chose it, sets the kind to note, which is what the parser falls back to.
    public static func removing(_ chip: CaptureChip, from draft: CaptureDraft) -> CaptureDraft {
        var next = draft
        if chip.role == .kind {
            next.kind = draft.kind == nil ? .note : nil
            return next
        }
        guard let range = chip.range, range.upperBound <= draft.text.endIndex else { return draft }
        var text = draft.text
        text.replaceSubrange(range, with: " ")
        next.text = collapse(text)
        return next
    }

    /// `⌫` on an empty field: the last chip goes. A blank line only has a kind you picked.
    public static func removingLast(from draft: CaptureDraft, context: CaptureContext) -> CaptureDraft {
        guard let last = chips(for: draft, context: context).last(where: { $0.role == .kind || $0.range != nil }) else {
            return draft
        }
        return removing(last, from: draft)
    }

    /// An inline edit of a chip's value. The new words replace the token in the line, so Core reads them as it reads
    /// anything typed. Nil when the parser does not read the new words as the same kind of chip, so a bad edit never
    /// changes the line. An empty value removes the chip.
    public static func editing(
        _ chip: CaptureChip, to value: String, in draft: CaptureDraft, context: CaptureContext
    ) -> CaptureDraft? {
        let typed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chip.role != .kind else { return nil }
        if typed.isEmpty { return chip.range == nil ? draft : removing(chip, from: draft) }
        var words = typed
        if chip.role == .time {
            // "14:30", "3pm" and "@14:30" all mean the same time.
            words = "@" + (typed.hasPrefix("@") ? String(typed.dropFirst()) : typed)
        }
        var text = draft.text
        if let range = chip.range {
            guard range.upperBound <= text.endIndex else { return nil }
            text.replaceSubrange(range, with: words)
        } else {
            text = text.trimmingCharacters(in: .whitespaces) + " " + words
        }
        var next = draft
        next.text = text
        let parsed = parse(next, context: context)
        let role = CaptureToken.Kind(rawValue: chip.role.rawValue)
        guard parsed.tokens.contains(where: { $0.kind == role && trimmed($0, in: text).text == words }) else { return nil }
        if chip.role == .time, parsed.occurredAt == nil { return nil }
        if chip.role == .duration, parsed.durationS == nil { return nil }
        return next
    }

    /// What an inline edit starts from: the time without its "@", the duration as typed.
    public static func editableValue(_ chip: CaptureChip, in draft: CaptureDraft) -> String {
        guard let range = chip.range, range.upperBound <= draft.text.endIndex else { return "" }
        return chip.role == .time ? chip.value : String(draft.text[range])
    }

    // MARK: The duplicate offer

    /// An entry a collector already found that this line looks like: same ticket, same kind, same day (section 4.3).
    public static func duplicate(of draft: CaptureDraft, in found: [Entry], context: CaptureContext) -> Entry? {
        guard !draft.isBlank else { return nil }
        let parsed = parse(draft, context: context)
        guard let ticket = parsed.ticket else { return nil }
        let kind = draft.kind ?? parsed.kind
        let day = parsed.day.description
        return found.first {
            $0.origin == .collected && $0.status == .accepted && $0.kind == kind && $0.day == day
                && $0.ticket?.key == ticket.key
        }
    }

    /// "Looks like the same merge GitHub already found."
    public static func duplicateMessage(_ entry: Entry) -> String {
        String(localized: "Looks like the same \(noun(entry.kind)) \(sourceName(entry.source)) already found.")
    }

    // MARK: Words

    /// The kind's name on its chip.
    public static func kindName(_ kind: EntryKind) -> String {
        switch kind {
        case .prOpened: String(localized: "PR opened")
        case .prMerged: String(localized: "PR merged")
        case .shipped: String(localized: "Shipped")
        case .workDone: String(localized: "Work done")
        case .reviewGiven: String(localized: "Review")
        case .docReviewed: String(localized: "Doc reviewed")
        case .initiativeStarted: String(localized: "Initiative")
        case .initiativeProgress: String(localized: "Initiative progress")
        case .incidentHandled: String(localized: "Incident")
        case .oncallShift: String(localized: "On call")
        case .discussionRaised: String(localized: "Discussion")
        case .decisionChallenged: String(localized: "Decision challenged")
        case .meetingLed: String(localized: "Meeting led")
        case .mentoring: String(localized: "Mentoring")
        case .docWritten: String(localized: "Doc")
        case .genaiSession: String(localized: "AI session")
        case .genaiUsage: String(localized: "AI usage")
        case .presenceSpan: String(localized: "Presence")
        case .meetingAttended: String(localized: "Meeting")
        case .note: String(localized: "Note")
        }
    }

    /// The kind as a noun in a sentence.
    static func noun(_ kind: EntryKind) -> String {
        switch kind {
        case .prMerged: String(localized: "merge")
        case .prOpened: String(localized: "pull request")
        case .shipped: String(localized: "release")
        case .workDone: String(localized: "piece of work")
        case .reviewGiven: String(localized: "review")
        case .docReviewed: String(localized: "doc review")
        case .initiativeStarted, .initiativeProgress: String(localized: "initiative")
        case .incidentHandled: String(localized: "incident")
        case .oncallShift: String(localized: "on-call shift")
        case .discussionRaised: String(localized: "discussion")
        case .decisionChallenged: String(localized: "challenge")
        case .meetingLed, .meetingAttended: String(localized: "meeting")
        case .mentoring: String(localized: "mentoring")
        case .docWritten: String(localized: "doc")
        case .genaiSession, .genaiUsage: String(localized: "AI session")
        case .presenceSpan: String(localized: "span")
        case .note: String(localized: "note")
        }
    }

    /// A collector's source as people write it.
    static func sourceName(_ source: String?) -> String {
        guard let source, let first = source.first else { return String(localized: "a collector") }
        switch source.lowercased() {
        case "github": return String(localized: "GitHub")
        case "gitlab": return String(localized: "GitLab")
        default: return first.uppercased() + source.dropFirst()
        }
    }

    /// "45m", "2h", "1h 30m".
    public static func durationText(_ seconds: Int64) -> String {
        let minutes = seconds / 60
        let (h, m) = (minutes / 60, minutes % 60)
        if h == 0 { return String(localized: "\(m)m") }
        return m == 0 ? String(localized: "\(h)h") : String(localized: "\(h)h \(m)m")
    }

    /// "PR #412" for a pull request, the key for a ticket, the host for anything else.
    static func linkName(_ url: String) -> String {
        let parts = url.split(separator: "/", omittingEmptySubsequences: true)
        if let pull = parts.firstIndex(of: "pull"), pull + 1 < parts.count { return String(localized: "PR #\(parts[pull + 1])") }
        if let browse = parts.firstIndex(of: "browse"), browse + 1 < parts.count { return String(parts[browse + 1]) }
        return URL(string: url)?.host() ?? url
    }

    private static func kindChip(_ kind: EntryKind, ticketClass: TicketClass?) -> CaptureChip {
        CaptureChip(
            role: .kind, label: String(localized: "kind"), value: kindName(kind), family: EntryKind.family(for: kind, ticketClass: ticketClass),
            range: nil, isFigure: false)
    }

    /// A token without the space a pattern may take after it ("@14:30 " before "~45m"), so editing or removing the
    /// chip never joins the words around it.
    private static func trimmed(_ token: CaptureToken, in text: String) -> CaptureToken {
        var end = token.range.upperBound
        while end > token.range.lowerBound, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        let range = token.range.lowerBound..<end
        return CaptureToken(kind: token.kind, text: String(text[range]), range: range)
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}
