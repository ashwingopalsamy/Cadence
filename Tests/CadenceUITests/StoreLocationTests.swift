import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// Where the sandboxed app finds the store, and that it never quietly finds another one.
@Suite struct StoreLocationTests {
    static let realHome = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func withoutCadenceHomeTheStoreIsInTheRealHomesApplicationSupport() {
        let location = StoreLocation.resolve(environment: [:], realHome: Self.realHome)
        #expect(location.databasePath == "/Users/someone/Library/Application Support/Cadence/cadence.db")
    }

    @Test func cadenceHomeIsTheStoreEvenWhenItWillNotBeReachable() {
        // The sandbox denies this path; the location still names it, so the read fails and the error shows.
        let location = StoreLocation.resolve(environment: ["CADENCE_HOME": "/Users/someone/dev/build/dev-home"], realHome: Self.realHome)
        #expect(location.databasePath == "/Users/someone/dev/build/dev-home/cadence.db")
        #expect(location.databasePath?.contains("Application Support/Cadence/") == false)
    }

    @Test func aTildeExpandsAgainstTheRealHomeNotTheContainer() {
        let location = StoreLocation.resolve(environment: ["CADENCE_HOME": "~/dev-home"], realHome: Self.realHome)
        #expect(location.databasePath == "/Users/someone/dev-home/cadence.db")
    }

    @Test func noHomeAndNoCadenceHomeIsAnErrorNotAGuess() {
        let location = StoreLocation.resolve(environment: [:], realHome: nil)
        #expect(location == .failed(StoreFailure(detail: "Cadence could not find your home folder")))
        #expect(location.databasePath == nil)
        // A tilde cannot be expanded without a home either.
        #expect(StoreLocation.resolve(environment: ["CADENCE_HOME": "~/dev-home"], realHome: nil).databasePath == nil)
    }

    @Test func noHomeStillUnderstandsAnAbsoluteCadenceHome() {
        let location = StoreLocation.resolve(environment: ["CADENCE_HOME": "/tmp/acme-home"], realHome: nil)
        #expect(location.databasePath == "/tmp/acme-home/cadence.db")
    }

    @Test func theRealHomeComesFromThePasswordDatabase() throws {
        let home = try #require(StoreLocation.realHome())
        #expect(home.path.hasPrefix("/"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }
}
