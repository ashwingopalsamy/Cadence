import Foundation

/// Runs `gh api graphql` through a `ProcessRunner` and returns checked JSON. Argv only, never a shell.
/// Cadence never sees a token: gh holds the login, and only the variables below reach its environment.
struct GitHubGraphQL: Sendable {
    /// The only variables passed on to gh (docs/SPEC.md section 10.3).
    static let passthrough = ["GH_HOST", "HOME", "PATH", "LANG", "TZ"]

    let runner: any ProcessRunner
    let gh: String
    let environment: [String: String]
    let workingDirectory: URL

    func call(_ query: String, variables: [(String, String)]) throws(CadenceError) -> JSONValue {
        guard gh.hasPrefix("/") else { throw .validation("gh must be an absolute path, not '\(gh)'") }
        var env: [String: String] = [:]
        for key in Self.passthrough { if let value = environment[key] { env[key] = value } }
        var argv = ["api", "graphql", "-f", "query=\(query)"]
        for (key, value) in variables { argv += ["-f", "\(key)=\(value)"] }
        let request = ProcessRequest(executable: gh, arguments: argv, environment: env, workingDirectory: workingDirectory)

        let result: ProcessResult
        do {
            result = try runner.run(request)
        } catch let error as CadenceError {
            throw error
        } catch {
            throw .io("could not run gh: \(error)")
        }
        if result.timedOut { throw .io("gh timed out; nothing was collected") }
        guard result.termination == .exited(0) else {
            var why: String
            switch result.termination {
            case .exited(let code): why = "gh exited with status \(code)"
            case .signalled(let signal): why = "gh was stopped by signal \(signal)"
            }
            let detail = Self.messages(in: result.stdout) ?? Self.tail(result.stderrTail)
            if !detail.isEmpty { why += ": \(detail)" }
            throw .io(why)
        }
        if result.stdoutTruncated { throw .io("gh printed more than the allowed output; nothing was collected") }

        let root = try Self.parse(result.stdout)
        if let errors = root["errors"], !errors.isNull, errors.arrayValue?.isEmpty != true {
            let found = Self.messages(in: errors)
            throw .io("GitHub returned errors" + (found.map { ": \($0)" } ?? ""))
        }
        guard root["data"]?.objectValue != nil else { throw .io("gh output has no data object") }
        return root
    }

    // MARK: - Parsing

    /// gh's JSON can hold floats or huge ids in fields Cadence never reads. Those numbers stay as their text
    /// instead of failing the parse; every field the collector reads is a string or a safe integer.
    static func parse(_ data: Data) throws(CadenceError) -> JSONValue {
        do {
            return try JSONParser.parseKeepingNumberText(bytes: Array(data))
        } catch {
            throw .io("gh output is not valid JSON (\(error))")
        }
    }

    private static func tail(_ data: Data) -> String {
        let cleaned = String(String.UnicodeScalarView(
            String(decoding: data, as: UTF8.self).unicodeScalars.map { $0.value < 0x20 && $0 != "\n" ? " " : $0 }))
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 400 ? "..." + trimmed.suffix(400) : trimmed
    }

    /// The `message` of each GraphQL error in `value`, joined, or nil when there are none.
    private static func messages(in value: JSONValue) -> String? {
        guard let list = value.arrayValue else { return nil }
        let texts = list.compactMap { $0["message"]?.stringValue }.prefix(3)
        return texts.isEmpty ? nil : texts.joined(separator: "; ")
    }

    private static func messages(in stdout: Data) -> String? {
        guard let root = try? parse(stdout), let errors = root["errors"] else { return nil }
        return messages(in: errors)
    }
}
