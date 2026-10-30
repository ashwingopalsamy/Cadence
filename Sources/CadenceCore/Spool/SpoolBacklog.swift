import Foundation

/// How much hook spool is waiting to be drained into the ledger (docs/SPEC.md section 9.3). Spool files stay for
/// 14 days after they are drained, so the backlog is what lies beyond each file's saved offset, not the files.
/// Read only: it never opens the store.
public struct SpoolBacklog: Sendable, Equatable {
    /// Files holding at least one complete line that has not been drained.
    public var files = 0
    /// Complete lines not yet drained.
    public var lines = 0
    /// When the oldest waiting line was written. Nil when there is none, or when its time cannot be read.
    public var oldest: Date?
    /// Spool files present, drained or not.
    public var spoolFiles = 0
    /// False when the drain state exists but cannot be read, so waiting lines cannot be told from drained ones.
    public var stateReadable = true

    public static func scan(roots: FileRoots) -> SpoolBacklog {
        var backlog = SpoolBacklog()
        let manager = FileManager.default
        let names = ((try? manager.contentsOfDirectory(atPath: roots.spool.path)) ?? [])
            .filter { SpoolDrain.isSpoolFile($0) }.sorted()
        backlog.spoolFiles = names.count
        var offsets: [String: Int] = [:]
        switch SpoolDrain.offsetState(in: roots) {
        case .missing: break
        case .loaded(let saved): offsets = saved
        case .unreadable: backlog.stateReadable = false
        }
        for name in names {
            let url = roots.spool.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            let bytes = [UInt8](data)
            var offset = offsets[name] ?? 0
            if offset > bytes.count { offset = 0 }  // the file was replaced by a shorter one, as the drain assumes
            // An unfinished last line is not waiting yet; the drain leaves it alone too.
            guard let end = bytes.lastIndex(of: 0x0A).map({ $0 + 1 }), end > offset else { continue }
            let region = bytes[offset..<end]
            backlog.files += 1
            backlog.lines += region.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            let firstEnd = region.firstIndex(of: 0x0A) ?? region.endIndex
            var written = SpoolDrain.parse(region[region.startIndex..<firstEnd])?.date
            if written == nil {
                written = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            }
            if let written, backlog.oldest.map({ written < $0 }) ?? true { backlog.oldest = written }
        }
        return backlog
    }

    /// "under a minute", "5 min", "4 h" up to 47 hours, then "2 days".
    public static func ageText(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        if whole < 60 { return "under a minute" }
        if whole < 3600 { return "\(whole / 60) min" }
        if whole < 48 * 3600 { return "\(whole / 3600) h" }
        return "\(whole / 86400) days"
    }
}
