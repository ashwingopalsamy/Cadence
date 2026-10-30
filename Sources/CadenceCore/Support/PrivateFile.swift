import Foundation

/// Writes files only the owner can read (mode 0600), atomically: a temporary file beside the target,
/// fsync, then rename. Used for config, proof exports and anything else that holds work-log data.
public enum PrivateFile {
    public static func save(_ bytes: [UInt8], to url: URL) throws(CadenceError) {
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
}
