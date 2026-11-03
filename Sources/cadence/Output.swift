import ArgumentParser
import CadenceCore
import Foundation

/// What a command produces: plain text for people, one JSON object for `--json`.
struct Rendered {
    var human: String
    var json: JSONValue
    /// True when the command already wrote its own output (NDJSON).
    var streamed = false
}

/// The flag every command shares.
struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Print one JSON object instead of text.") var json = false

    /// Runs `body`, prints its result, and turns a `CadenceError` into `cadence: <message>` on stderr and
    /// the exit code from docs/SPEC.md section 9.5. Entry titles are never written to stderr.
    func run(_ body: (CLIContext) throws -> Rendered) throws {
        do {
            let rendered = try body(CLIContext.current())
            try emit(rendered)
        } catch let error as CadenceError {
            throw fail(error)
        } catch let error as ExitCode {
            throw error
        } catch {
            throw fail(.io(String(describing: error)))
        }
    }

    func emit(_ rendered: Rendered) throws(CadenceError) {
        if rendered.streamed { return }
        if json {
            writeLine(try Self.canonical(rendered.json), to: FileHandle.standardOutput)
        } else {
            writeLine(rendered.human, to: FileHandle.standardOutput)
        }
    }

    static func canonical(_ value: JSONValue) throws(CadenceError) -> String {
        do {
            return try CanonicalJSON.string(value)
        } catch {
            throw .io("cannot encode the result as JSON")
        }
    }
}

func fail(_ error: CadenceError) -> ExitCode {
    writeLine("cadence: \(error.message)", to: FileHandle.standardError)
    return ExitCode(error.exitCode)
}

func writeLine(_ text: String, to handle: FileHandle) {
    handle.write(Data((text + "\n").utf8))
}

// MARK: - Argument parsing

enum Args {
    static func date(_ text: String?, option: String = "date") throws(CadenceError) -> LocalDate? {
        guard let text else { return nil }
        guard let date = LocalDate(text) else {
            throw .validation("--\(option): '\(text)' is not a date; use YYYY-MM-DD")
        }
        return date
    }

    static func required(_ text: String, option: String) throws(CadenceError) -> LocalDate {
        guard let date = try date(text, option: option) else { throw .validation("--\(option) is required") }
        return date
    }

    static func values<E: RawRepresentable & CaseIterable>(_ texts: [String], option: String, as _: E.Type) throws(CadenceError) -> [E]
    where E.RawValue == String {
        var out: [E] = []
        for text in texts {
            guard let value = E(rawValue: text) else {
                let valid = E.allCases.map(\.rawValue).joined(separator: ", ")
                throw .validation("--\(option): '\(text)' is not valid; use one of \(valid)")
            }
            out.append(value)
        }
        return out
    }
}
