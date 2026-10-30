/// Who wrote an event (docs/SPEC.md section 7.3, `events.actor`).
public enum Actor: Sendable, Hashable {
    case app
    case cli
    case mcp
    case hook
    case collector(String)
    case importer(String)
}

extension Actor: RawRepresentable {
    /// `app`, `cli`, `mcp`, `hook`, `collector:<name>` or `import:<name>`.
    public var rawValue: String {
        switch self {
        case .app: "app"
        case .cli: "cli"
        case .mcp: "mcp"
        case .hook: "hook"
        case .collector(let name): "collector:\(name)"
        case .importer(let name): "import:\(name)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "app": self = .app
        case "cli": self = .cli
        case "mcp": self = .mcp
        case "hook": self = .hook
        default:
            if let name = Actor.name(after: "collector:", in: rawValue) {
                self = .collector(name)
            } else if let name = Actor.name(after: "import:", in: rawValue) {
                self = .importer(name)
            } else {
                return nil
            }
        }
    }

    /// Collector and import names: lowercase ASCII letters, digits and hyphens, 1 to 64 characters.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count) else { return false }
        return name.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
    }

    private static func name(after prefix: String, in raw: String) -> String? {
        guard raw.hasPrefix(prefix) else { return nil }
        let name = String(raw.dropFirst(prefix.count))
        return isValidName(name) ? name : nil
    }
}
