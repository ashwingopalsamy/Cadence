import Foundation
import Testing

@testable import CadenceCore

@Suite struct InterfaceTests {
    @Test func actorRawValuesRoundTrip() {
        let actors: [Actor] = [.app, .cli, .mcp, .hook, .collector("github"), .importer("october-app")]
        for actor in actors {
            #expect(Actor(rawValue: actor.rawValue) == actor)
        }
        #expect(Actor(rawValue: "collector:") == nil)
        #expect(Actor(rawValue: "collector:Bad Name") == nil)
        #expect(Actor(rawValue: "root") == nil)
    }

    @Test func exitCodesMatchTheSpec() {
        #expect(CadenceError.usage("x").exitCode == 1)
        #expect(CadenceError.validation("x").exitCode == 2)
        #expect(CadenceError.storeBusy.exitCode == 3)
        #expect(CadenceError.notFound("x").exitCode == 4)
        #expect(CadenceError.schemaTooNew(found: 2, supported: 1).exitCode == 2)
    }

    @Test func fileRootsHonourCadenceHome() {
        let home = URL(fileURLWithPath: "/home/someone", isDirectory: true)
        let roots = FileRoots.resolve(environment: ["CADENCE_HOME": "~/dev-home"], userHome: home)
        #expect(roots.home.path == "/home/someone/dev-home")
        #expect(roots.database.lastPathComponent == "cadence.db")
        #expect(roots.spool.lastPathComponent == "spool")
    }

    @Test func fileRootsDefault() {
        let home = URL(fileURLWithPath: "/home/someone", isDirectory: true)
        let roots = FileRoots.resolve(environment: [:], userHome: home)
        #if os(macOS)
        #expect(roots.home.path == "/home/someone/Library/Application Support/Cadence")
        #else
        #expect(roots.home.path == "/home/someone/.local/share/cadence")
        #endif
    }

    @Test func manualClockMoves() {
        let clock = ManualClock(Date(timeIntervalSince1970: 0))
        clock.advance(by: 90)
        #expect(clock.now() == Date(timeIntervalSince1970: 90))
    }

    @Test func seededRandomIsDeterministic() {
        let a = SeededRandomSource(seed: 42).bytes(32)
        let b = SeededRandomSource(seed: 42).bytes(32)
        #expect(a == b)
        #expect(a.count == 32)
        #expect(SeededRandomSource(seed: 43).bytes(32) != a)
    }

    @Test func jsonValueLiterals() {
        let value: JSONValue = ["a": 1, "b": [true, nil, "x"]]
        #expect(value["a"]?.intValue == 1)
        #expect(value["b"]?.arrayValue?.count == 3)
    }
}
