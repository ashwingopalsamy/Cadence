import Foundation
import Testing

@testable import CadenceCore

@Suite struct TicketClassifierTests {
    private func standard() throws -> TicketClassifier {
        try TicketClassifier(rules: .standard)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let text: String
        let key: String?
        let selfInitiated: Bool
        var testDescription: String { text }
    }

    static let defaultCases: [Case] = [
        Case(text: "ACME-482913", key: "ACME-482913", selfInitiated: false),
        Case(text: "ACME-000000", key: "ACME-000000", selfInitiated: true),
        Case(text: "ACME-000", key: "ACME-000", selfInitiated: true),
        Case(text: "ACME-0000000", key: "ACME-0000000", selfInitiated: true),
        Case(text: "ACME-100000", key: "ACME-100000", selfInitiated: false),
        Case(text: "ACME-000001", key: "ACME-000001", selfInitiated: false),
        Case(text: "acme-123456", key: nil, selfInitiated: false),
        Case(text: "A-123456", key: nil, selfInitiated: false),
        Case(text: "ACME-12", key: nil, selfInitiated: false),
        Case(text: "ACME-123456789", key: nil, selfInitiated: false),
        // No boundary between X and ACME, so the whole token is the key.
        Case(text: "XACME-123456", key: "XACME-123456", selfInitiated: false),
        Case(text: "(ACME-482913),", key: "ACME-482913", selfInitiated: false),
        Case(text: "https://tickets.example.com/browse/ACME-482913", key: "ACME-482913", selfInitiated: false),
        Case(text: "Fixed flaky test ACME-482913 today", key: "ACME-482913", selfInitiated: false),
        Case(text: "no ticket here", key: nil, selfInitiated: false),
        Case(text: "", key: nil, selfInitiated: false),
    ]

    @Test(arguments: defaultCases)
    func defaultRulesFirstTicket(_ c: Case) throws {
        let match = try standard().firstTicket(in: c.text)
        #expect(match?.key == c.key)
        if let match {
            #expect(match.selfInitiated == c.selfInitiated)
            #expect(String(c.text[match.range]) == match.key)
            #expect(match.key.hasSuffix(match.number))
        }
    }

    @Test func numberGroupIsReported() throws {
        let match = try standard().firstTicket(in: "ACME-482913")
        #expect(match?.number == "482913")
    }

    struct TitleCase: Sendable, CustomTestStringConvertible {
        let title: String
        let window: Int
        let key: String?
        var testDescription: String { "\(title) @\(window)" }
    }

    static let titleCases: [TitleCase] = [
        TitleCase(title: "ACME-482913 Ship retry budget", window: 12, key: "ACME-482913"),
        TitleCase(title: "Ship retry budget ACME-482913", window: 12, key: nil),
        // "Ship it now " is 12 characters, so the key starts at offset 12: outside.
        TitleCase(title: "Ship it now ACME-482913", window: 12, key: nil),
        // 11 characters then the key: starts at offset 11, inside.
        TitleCase(title: "Ship it no ACME-482913", window: 12, key: "ACME-482913"),
        TitleCase(title: "Ship it no ACME-482913", window: 11, key: nil),
        // Multibyte characters count as one Character each: 7 before the space, key at offset 8.
        TitleCase(title: "Ünïcödé ACME-482913", window: 12, key: "ACME-482913"),
        TitleCase(title: "Ünïcödé ACME-482913", window: 8, key: nil),
        TitleCase(title: "Ünïcödé ACME-482913", window: 9, key: "ACME-482913"),
        // Combining sequence: "e" + U+0301 is one Character, so the key starts at offset 5.
        TitleCase(title: "e\u{301}e\u{301}e\u{301}e\u{301} ACME-482913", window: 6, key: "ACME-482913"),
        TitleCase(title: "e\u{301}e\u{301}e\u{301}e\u{301} ACME-482913", window: 5, key: nil),
        // An early match wins over a later one.
        TitleCase(title: "[ACME-482913] Ship retry budget ACME-111111", window: 12, key: "ACME-482913"),
        TitleCase(title: "", window: 12, key: nil),
    ]

    @Test(arguments: titleCases)
    func titleWindowCountsCharacters(_ c: TitleCase) throws {
        let classifier = try TicketClassifier(rules: TicketRules(titleWindow: c.window))
        let match = classifier.titleTicket(in: c.title)
        #expect(match?.key == c.key)
        if let match {
            #expect(String(c.title[match.range]) == match.key)
        }
    }

    @Test func titleFlagsSelfInitiatedAndIgnoresLateOnlyMatch() throws {
        let classifier = try standard()
        #expect(classifier.titleTicket(in: "Ship the retry budget fix ACME-482913") == nil)
        #expect(classifier.titleTicket(in: "ACME-000000 Tidy")?.selfInitiated == true)
    }

    @Test func allTicketsKeepsOrderAndDeduplicates() throws {
        let text = "ACME-200001 then ACME-100001, again ACME-200001 and ACME-000000 plus ACME-100001"
        let keys = try standard().allTickets(in: text).map(\.key)
        #expect(keys == ["ACME-200001", "ACME-100001", "ACME-000000"])
        #expect(try standard().allTickets(in: "nothing").isEmpty)
    }

    @Test func allTicketsKeepsFirstRange() throws {
        let text = "ACME-200001 and ACME-200001"
        let all = try standard().allTickets(in: text)
        #expect(all.count == 1)
        #expect(text.distance(from: text.startIndex, to: all[0].range.lowerBound) == 0)
    }

    @Test func customPatternWithDifferentGroupPositions() throws {
        let rules = TicketRules(pattern: #"(?<key>PROJ-(?<num>\d+))"#)
        let classifier = try TicketClassifier(rules: rules)
        let match = classifier.firstTicket(in: "see PROJ-77 now")
        #expect(match?.key == "PROJ-77")
        #expect(match?.number == "77")
        #expect(match?.selfInitiated == false)

        // The num group appears before the key group in the pattern.
        let swapped = TicketRules(pattern: #"(?<num>\d+)@(?<key>[a-z]+)"#)
        let c2 = try TicketClassifier(rules: swapped)
        let m2 = c2.firstTicket(in: "id 123@abc")
        #expect(m2?.key == "abc")
        #expect(m2?.number == "123")
    }

    @Test func customSelfInitiatedPattern() throws {
        let rules = TicketRules(selfInitiated: "^9+$")
        let classifier = try TicketClassifier(rules: rules)
        #expect(classifier.firstTicket(in: "ACME-999999")?.selfInitiated == true)
        #expect(classifier.firstTicket(in: "ACME-000000")?.selfInitiated == false)
        #expect(classifier.firstTicket(in: "ACME-999991")?.selfInitiated == false)
    }

    @Test func missingNumGroupThrowsValidation() {
        let rules = TicketRules(pattern: #"(?<key>PROJ-\d+)"#)
        do {
            _ = try TicketClassifier(rules: rules)
            Issue.record("expected a validation error")
        } catch {
            guard case .validation(let message) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(message.contains("num"))
        }
    }

    @Test func missingKeyGroupThrowsValidation() {
        let rules = TicketRules(pattern: #"PROJ-(?<num>\d+)"#)
        do {
            _ = try TicketClassifier(rules: rules)
            Issue.record("expected a validation error")
        } catch {
            guard case .validation(let message) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(message.contains("key"))
        }
    }

    @Test func invalidRegexThrowsValidation() {
        for rules in [
            TicketRules(pattern: #"(?<key>PROJ-(?<num>\d+"#),
            TicketRules(selfInitiated: "([0"),
        ] {
            do {
                _ = try TicketClassifier(rules: rules)
                Issue.record("expected a validation error")
            } catch {
                guard case .validation = error else {
                    Issue.record("wrong error \(error)")
                    return
                }
            }
        }
    }

    @Test(arguments: [0, -1, 201, 1000])
    func titleWindowOutOfRangeThrows(_ window: Int) {
        do {
            _ = try TicketClassifier(rules: TicketRules(titleWindow: window))
            Issue.record("expected a validation error")
        } catch {
            guard case .validation(let message) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(message.contains("titleWindow"))
        }
    }

    @Test(arguments: [1, 12, 200])
    func titleWindowBoundsAccepted(_ window: Int) throws {
        _ = try TicketClassifier(rules: TicketRules(titleWindow: window))
    }

    @Test func defaultsMatchTheSpec() {
        #expect(TicketRules.standard == TicketRules())
        #expect(TicketRules.standard.titleWindow == 12)
        #expect(TicketRules.standard.selfInitiated == "^0+$")
        #expect(TicketRules.standard.linkTemplate == nil)
    }

    @Test func linkWithAndWithoutTemplate() throws {
        let withTemplate = try TicketClassifier(
            rules: TicketRules(linkTemplate: "https://tickets.example.com/browse/{key}"))
        #expect(withTemplate.link(for: "ACME-482913") == "https://tickets.example.com/browse/ACME-482913")
        #expect(try standard().link(for: "ACME-482913") == nil)
    }
}
