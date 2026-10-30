import Foundation

/// A ticket found in text.
public struct TicketMatch: Sendable, Hashable {
    /// The full key, for example `ACME-482913`.
    public let key: String
    /// The `num` group, for example `482913`.
    public let number: String
    /// True when the number matches the `selfInitiated` pattern.
    public let selfInitiated: Bool
    /// Where the key was found in the input.
    public let range: Range<String.Index>

    public init(key: String, number: String, selfInitiated: Bool, range: Range<String.Index>) {
        self.key = key
        self.number = number
        self.selfInitiated = selfInitiated
        self.range = range
    }
}

/// The `tickets` block of config (docs/SPEC.md section 7.4).
public struct TicketRules: Sendable, Hashable {
    public static let defaultPattern = #"\b(?<key>[A-Z][A-Z0-9]{1,9}-(?<num>\d{3,8}))\b"#
    public static let defaultSelfInitiated = "^0+$"

    /// Must contain the named groups `key` and `num`.
    public var pattern: String
    /// How many leading characters of a PR title are searched. 1...200.
    public var titleWindow: Int
    /// Applied to the whole `num` value as written.
    public var selfInitiated: String
    /// For example `https://tickets.example.com/browse/{key}`.
    public var linkTemplate: String?

    public init(
        pattern: String = defaultPattern,
        titleWindow: Int = 12,
        selfInitiated: String = defaultSelfInitiated,
        linkTemplate: String? = nil
    ) {
        self.pattern = pattern
        self.titleWindow = titleWindow
        self.selfInitiated = selfInitiated
        self.linkTemplate = linkTemplate
    }

    public static let standard = TicketRules()
}

/// Finds and classifies ticket keys (docs/SPEC.md sections 4.3 and 10.3).
///
/// Uses `NSRegularExpression` (ICU) because named groups behave the same on macOS and on Linux
/// corelibs. Both compiled expressions are immutable after `init` and `NSRegularExpression` is
/// documented as thread-safe, so the unchecked Sendable conformance below is sound.
public struct TicketClassifier: Sendable {
    private struct Compiled: @unchecked Sendable {
        let pattern: NSRegularExpression
        let selfInitiated: NSRegularExpression
    }

    private let compiled: Compiled
    private let titleWindow: Int
    private let linkTemplate: String?

    /// Compiles and validates the rules.
    public init(rules: TicketRules) throws(CadenceError) {
        guard (1...200).contains(rules.titleWindow) else {
            throw .validation("tickets.titleWindow must be between 1 and 200, got \(rules.titleWindow)")
        }
        let pattern: NSRegularExpression
        do {
            pattern = try NSRegularExpression(pattern: rules.pattern)
        } catch {
            throw .validation("tickets.pattern is not a valid regular expression: \(rules.pattern)")
        }
        for group in ["key", "num"] where !rules.pattern.contains("(?<\(group)>") {
            throw .validation("tickets.pattern must contain a named group \"\(group)\", for example (?<\(group)>...)")
        }
        let selfInitiated: NSRegularExpression
        do {
            selfInitiated = try NSRegularExpression(pattern: rules.selfInitiated)
        } catch {
            throw .validation("tickets.selfInitiated is not a valid regular expression: \(rules.selfInitiated)")
        }
        self.compiled = Compiled(pattern: pattern, selfInitiated: selfInitiated)
        self.titleWindow = rules.titleWindow
        self.linkTemplate = rules.linkTemplate
    }

    /// First ticket anywhere in free text.
    public func firstTicket(in text: String) -> TicketMatch? {
        matches(in: text).first
    }

    /// Every ticket in text, in order, de-duplicated by key (the first occurrence wins).
    public func allTickets(in text: String) -> [TicketMatch] {
        var seen = Set<String>()
        return matches(in: text).filter { seen.insert($0.key).inserted }
    }

    /// The first ticket whose match starts within the first `titleWindow` characters of a PR title.
    public func titleTicket(in title: String) -> TicketMatch? {
        matches(in: title).first { match in
            title.distance(from: title.startIndex, to: match.range.lowerBound) < titleWindow
        }
    }

    /// The link for a key, or nil when there is no template.
    public func link(for key: String) -> String? {
        linkTemplate?.replacingOccurrences(of: "{key}", with: key)
    }

    private func matches(in text: String) -> [TicketMatch] {
        let whole = NSRange(text.startIndex..., in: text)
        var result: [TicketMatch] = []
        for found in compiled.pattern.matches(in: text, range: whole) {
            let keyRange = found.range(withName: "key")
            let numRange = found.range(withName: "num")
            guard keyRange.location != NSNotFound, numRange.location != NSNotFound,
                let range = Range(keyRange, in: text), let numSpan = Range(numRange, in: text)
            else { continue }
            let number = String(text[numSpan])
            let numWhole = NSRange(number.startIndex..., in: number)
            let isSelf = compiled.selfInitiated.firstMatch(in: number, range: numWhole) != nil
            result.append(
                TicketMatch(key: String(text[range]), number: number, selfInitiated: isSelf, range: range))
        }
        return result
    }
}
