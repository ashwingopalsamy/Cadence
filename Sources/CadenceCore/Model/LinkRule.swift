import Foundation

/// The one rule for a link that may enter the ledger (docs/SPEC.md section 10.1), shared by `cadence log --link`,
/// the MCP tools and the envelope reader: `https`, or `http` on a host listed in `config.hosts`; a host; at most
/// 2,048 characters; no credentials; no spaces, control characters or bidirectional format characters.
enum LinkRule {
    static let maxLength = 2048

    enum Refusal: Sendable, Equatable {
        case tooLong
        case characters
        case scheme
        case noHost
        case credentials

        /// The sentence for `cadence log` and the MCP tools. Whether http can be allowed changes the scheme wording.
        func message(httpHosts: Set<String>) -> String {
            switch self {
            case .tooLong: "at most \(LinkRule.maxLength) characters"
            case .characters: "must not hold spaces, control or bidirectional characters"
            case .scheme:
                httpHosts.isEmpty
                    ? "only https links are accepted" : "only https links, or http on a host in config.hosts, are accepted"
            case .noHost: "needs a host"
            case .credentials: "must not carry a user name or password"
            }
        }
    }

    /// Why `url` is not kept, or nil when it is. `httpHosts` are lowercased.
    static func refusal(_ url: String, httpHosts: Set<String>) -> Refusal? {
        guard url.count <= maxLength else { return .tooLong }
        guard !url.unicodeScalars.contains(where: { isForbidden($0) }) else { return .characters }
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased() else { return .scheme }
        guard scheme == "https" || scheme == "http" else { return .scheme }
        guard let host = parts.host?.lowercased(), !host.isEmpty else { return .noHost }
        guard parts.user == nil, parts.password == nil else { return .credentials }
        if scheme == "http", !httpHosts.contains(host) { return .scheme }
        return nil
    }

    static func isKept(_ url: String, httpHosts: Set<String>) -> Bool { refusal(url, httpHosts: httpHosts) == nil }

    /// Whitespace, controls (C0, DEL and C1) and the Unicode bidirectional format characters.
    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.properties.generalCategory == .control || Journal.isBidiFormat(scalar)
    }
}
