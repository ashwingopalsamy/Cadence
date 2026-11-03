import SwiftUI
import Testing

@testable import CadenceUI

/// The keyboard map of docs/SPEC.md section 4.8 and discreet mode of section 6.7, pinned in one place.
@MainActor @Suite struct KeyboardMapTests {
    @Test func theGlobalShortcutsAreControlOptionLNAndD() {
        #expect(HotkeyBindings.standard.all.map(\.display) == ["⌃⌥L", "⌃⌥N", "⌃⌥D"])
        #expect(HotkeyBindings.standard.all.map(\.action) == [.capture, .quickNote, .discreet])
    }

    @Test func theWindowSectionsAreCommandOneToFiveAndSettingsIsCommandComma() {
        let keys = WindowSection.allCases.compactMap { section in section.shortcut.map { (section, $0.character) } }
        #expect(keys.map(\.0) == [.today, .log, .insights, .recap, .proof, .settings])
        #expect(keys.map(\.1) == ["1", "2", "3", "4", "5", ","])
    }

    @Test func discreetModeTurnsTitlesIntoNumberedWordsAndHidesTempo() async throws {
        let home = DayStoreLoaderTests.Home()
        defer { home.remove() }
        let app = try await AppStateTests.make(home)
        app.discreet = true
        #expect(app.title("Review the ACME-101 change", index: 2, word: "Task") == "Task 3")
        #expect(app.title("Merged the retry budget", index: 0) == "Item 1")
        #expect(!app.showsTempo)
        app.discreet = false
        #expect(app.showsTempo)
    }
}
