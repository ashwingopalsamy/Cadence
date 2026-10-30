import CadenceCore
import Foundation
import Testing

@Suite struct ImportGenAICommandTests {
    static let vectors = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vectors/genai")
    static var csv: String { vectors.appendingPathComponent("acme-app.csv").path }
    static var map: String { vectors.appendingPathComponent("acme-app.json").path }

    @Test func dryRunPrintsTheSpecTableAndWritesNothing() throws {
        let home = CLIHome()
        defer { home.remove() }
        let result = try home.run(["import", "genai", Self.csv, "--map", Self.map, "--dry-run"])
        #expect(result.status == 0)
        let lines = result.stdout.trimmingCharacters(in: .newlines).split(separator: "\n").map(String.init)
        #expect(lines[0] == "map acme-app (map/1, csv) \u{00B7} 6 rows \u{2192} 4 days \u{00B7} tool claude-code")
        #expect(lines[1].hasPrefix("day") && lines[1].contains("requests") && lines[1].contains("tokens out"))
        #expect(lines[1].hasSuffix("other sources"))
        // 2026-10-01 sums two models: 118 requests, 51,302 tokens, $14.21.
        let first = try #require(lines.first { $0.hasPrefix("2026-10-01") })
        #expect(first.contains("118") && first.contains("51,302") && first.contains("$14.21") && first.hasSuffix("none"))
        let zero = try #require(lines.first { $0.hasPrefix("2026-10-02") })
        #expect(zero.contains("$0.00") && zero.hasSuffix("none"))
        let total = try #require(lines.first { $0.hasPrefix("total") })
        #expect(total.contains("494") && total.contains("225,357") && total.contains("$60.48"))
        #expect(lines.contains { $0.hasPrefix("skipped 1:") })
        #expect(lines.contains { $0.contains("row at line 6") })
        #expect(lines.last == "dry run: nothing written. Run again without --dry-run to import.")
        #expect(!result.stdout.contains("\u{2013}") && !result.stdout.contains("\u{2014}"))
        // Nothing written: no ledger was created.
        #expect(!FileManager.default.fileExists(atPath: home.database))
    }

    @Test func dryRunShowsOtherSourcesAndDeclaredDayKinds() throws {
        let home = CLIHome()
        defer { home.remove() }
        let day = "2026-10-28"
        // Another import for 28 October, 0.2% below the file's 96,115 output tokens, and a holiday on the 2nd.
        // The importer actor may write under any valid name, so seed the other source as a second import.
        let seed = home.home.appendingPathComponent("seed.csv")
        try FileManager.default.createDirectory(at: home.home, withIntermediateDirectories: true)
        try "date,model,requests,input,output,cost_usd\n\(day),model-a,1,1,95880,1.00\n".write(to: seed, atomically: true, encoding: .utf8)
        let seeded = try home.run(["import", "genai", seed.path, "--map", Self.map, "--name", "other-app"])
        #expect(seeded.status == 0)
        _ = try home.run(["day", "holiday", "2026-10-02"])
        let result = try home.run(["import", "genai", Self.csv, "--map", Self.map, "--dry-run"])
        #expect(result.status == 0)
        let line = try #require(result.stdout.split(separator: "\n").first { $0.hasPrefix(day) })
        #expect(line.contains("import:other-app 95,880 (0.2% apart)"))
        let holiday = try #require(result.stdout.split(separator: "\n").first { $0.hasPrefix("2026-10-02") })
        #expect(holiday.hasSuffix("holiday"))
    }

    @Test func dryRunJsonCarriesTheSameDays() throws {
        let home = CLIHome()
        defer { home.remove() }
        let json = try home.json(["import", "genai", Self.csv, "--map", Self.map, "--dry-run"])
        #expect(json["dry_run"]?.boolValue == true)
        #expect(json["days"]?.arrayValue?.count == 4)
        #expect(json["totals"]?["cost_micros"]?.intValue == 60_480_000)
        #expect(json["skipped"]?.arrayValue?.count == 1)
    }

    @Test func aRealImportWritesUsageRowsAndIsIdempotent() throws {
        let home = CLIHome()
        defer { home.remove() }
        let args = ["import", "genai", Self.csv, "--map", Self.map]
        let first = try home.json(args)
        let counts = try #require(first["counts"])
        #expect(counts["created"]?.intValue == 5 && counts["skipped"]?.intValue == 1 && counts["unchanged"]?.intValue == 0)
        #expect(first["source"]?.stringValue == "import:acme-app")
        #expect(first["since"]?.stringValue == "2026-10-01" && first["until"]?.stringValue == "2026-10-28")

        let again = try home.json(args)
        #expect(again["counts"]?["created"]?.intValue == 0 && again["counts"]?["unchanged"]?.intValue == 5)

        let summary = try home.json(["summary", "--range", "2026-10-01..2026-10-28"])
        #expect(summary["ai"]?["output_tokens"]?["value"]?.intValue == 225_357)

        let human = try home.run(args)
        #expect(human.stdout.hasPrefix("Imported import:acme-app for 2026-10-01 to 2026-10-28: 0 created"))
    }

    @Test func badInputsFailWithValidationOrNotFound() throws {
        let home = CLIHome()
        defer { home.remove() }
        #expect(try home.run(["import", "genai", "/nonexistent.csv", "--map", Self.map]).status == 4)
        #expect(try home.run(["import", "genai", Self.csv, "--map", Self.map, "--name", "Bad Name"]).status == 2)
        #expect(try home.run(["import", "genai", Self.map, "--map", Self.map]).status == 2)
    }
}
