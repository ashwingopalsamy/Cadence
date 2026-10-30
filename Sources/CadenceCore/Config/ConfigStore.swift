import Foundation

/// What `stat(2)` says about `config.json` (docs/SPEC.md section 10.2): collectors run only when the file
/// is owned by the current user and no group or other permission bit is set.
public struct ConfigFileCheck: Sendable, Equatable {
    public var exists: Bool
    public var ownedByUser: Bool
    public var mode: Int
    /// `exists && ownedByUser && (mode & 0o077) == 0`.
    public var safe: Bool
    /// Why the file is unsafe. Never includes file contents.
    public var problem: String?

    public init(exists: Bool, ownedByUser: Bool, mode: Int, safe: Bool, problem: String? = nil) {
        self.exists = exists
        self.ownedByUser = ownedByUser
        self.mode = mode
        self.safe = safe
        self.problem = problem
    }
}

public enum ConfigStore {
    /// Loads the file; a missing file gives `Config.defaults(timezone: fallbackZone)` and `exists == false`.
    /// An unsafe file still loads: the caller decides to disable collectors from the check.
    public static func load(from url: URL, fallbackZone: String) throws(CadenceError) -> (Config, ConfigFileCheck) {
        let check = check(url)
        guard check.exists else { return (Config.defaults(timezone: fallbackZone), check) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .io("cannot read \(url.lastPathComponent)")
        }
        return (try Config.parse(bytes: [UInt8](data), fallbackZone: fallbackZone), check)
    }

    /// Writes canonical JSON atomically with mode 0600: a 0600 temp file in the same folder, then rename.
    public static func save(_ config: Config, to url: URL) throws(CadenceError) {
        let bytes: [UInt8]
        do {
            bytes = try CanonicalJSON.bytes(config.json) + [0x0A]
        } catch {
            throw .validation("config cannot be written as canonical JSON")
        }
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .io("cannot create \(folder.lastPathComponent)")
        }
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw .io("cannot create a temporary file beside \(url.lastPathComponent)") }
        var ok = fchmod(fd, 0o600) == 0
        var offset = 0
        while ok && offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 { ok = false } else { offset += n }
        }
        ok = ok && fsync(fd) == 0
        ok = (close(fd) == 0) && ok
        guard ok, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw .io("cannot write \(url.lastPathComponent)")
        }
    }

    public static func check(_ url: URL) -> ConfigFileCheck {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            return ConfigFileCheck(exists: false, ownedByUser: false, mode: 0, safe: false)
        }
        let mode = Int(st.st_mode) & 0o7777
        let regular = (Int(st.st_mode) & 0o170000) == 0o100000
        let owned = st.st_uid == getuid()
        let safe = regular && owned && (mode & 0o077) == 0
        var problems: [String] = []
        let name = url.lastPathComponent
        if !regular { problems.append("\(name) is not a regular file") }
        if !owned { problems.append("\(name) is owned by another user; Cadence only trusts a file you own") }
        if (mode & 0o077) != 0 {
            let octal = String(mode, radix: 8)
            let padded = String(repeating: "0", count: max(0, 4 - octal.count)) + octal
            problems.append("\(name) is mode \(padded); run chmod 600 \(url.path)")
        }
        return ConfigFileCheck(
            exists: true, ownedByUser: owned, mode: mode, safe: safe,
            problem: problems.isEmpty ? nil : problems.joined(separator: ". "))
    }
}
