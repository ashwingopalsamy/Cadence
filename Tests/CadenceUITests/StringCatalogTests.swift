import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// Every string the interface shows lives in App/Resources/Localizable.xcstrings (docs/SPEC.md section 16), and the
/// app loads it through Bundle.main. A test process has no such table, so a lookup has to fall back to the key, which
/// is the English text, or none of the copy tests could pass.
@Suite struct StringCatalogTests {
    static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")

    static func catalog() throws -> (language: String, keys: [String]) {
        let data = try Data(contentsOf: catalogURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        return (json["sourceLanguage"] as? String ?? "", Array(strings.keys))
    }

    @Test func aLookupFallsBackToTheKeyWhenTheBundleHasNoTable() {
        #expect(String(localized: "Plan your day") == "Plan your day")
        #expect(String(localized: "Done, \(3) of \(5)") == "Done, 3 of 5")
        #expect(String(localized: "Sealed at \("17:40"), \(2) logged.") == "Sealed at 17:40, 2 logged.")
        #expect(String(localized: "Plan done \(78)%.") == "Plan done 78%.")
    }

    @Test func theInterfaceReadsTheSameEnglishWithoutAnyBundle() {
        #expect(PanelAction.planDay.title == "Plan your day")
        #expect(PanelAction.wrapUp(open: 2).title == "Wrap up, 2 open")
        #expect(PanelAction.wrapUp(open: 0).title == "Wrap up")
        #expect(AppState.tickAnnouncement(done: 3, planned: 5) == "Done, 3 of 5")
        #expect(PanelContent.Count(done: 3, planned: 5, held: true).text == "Logged, 3 of 5")
        #expect(SettingsPane.sources.title == "Sources")
        // The raw value stays the pane's name, so a window can open it by name whatever the title says.
        #expect(SettingsPane(rawValue: "Sources") == .sources)
    }

    @Test func theCatalogIsEnglishAndHoldsTheInterfaceStrings() throws {
        let catalog = try Self.catalog()
        #expect(catalog.language == "en")
        #expect(catalog.keys.count > 500)
        for key in ["Plan your day", "Wrap up, %lld open", "Done, %lld of %lld", "Seal as empty", "Not saved: %@."] {
            #expect(catalog.keys.contains(key), "\(key)")
        }
    }

    @Test func everyCatalogKeyKeepsTheCopyRules() throws {
        for key in try Self.catalog().keys { #expect(CopyRules.allows(key), "\(key)") }
    }
}
