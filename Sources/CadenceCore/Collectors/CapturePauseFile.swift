import Foundation

/// "Capture paused" as a file the app writes and the collector agent reads (docs/SPEC.md section 5.2): presence and
/// collectors are off until the time in it. It lives in `state/`, holds only an instant, and a missing or unreadable
/// file means capture is on.
public enum CapturePauseFile {
    public static func url(_ roots: FileRoots) -> URL { roots.state.appendingPathComponent("capture-paused.json") }

    /// Pauses until `until`, or resumes when it is nil.
    public static func write(_ until: Date?, roots: FileRoots) throws(CadenceError) {
        let file = url(roots)
        guard let until else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let bytes: [UInt8]
        do {
            bytes = try CanonicalJSON.bytes(["until": .string(Timestamp.utc(until))])
        } catch {
            throw .io("cannot encode the capture pause")
        }
        try PrivateFile.save(bytes + [0x0A], to: file)
    }

    /// When capture resumes, if it is paused at `now`.
    public static func pausedUntil(roots: FileRoots, now: Date) -> Date? {
        guard let data = PrivateFile.readOwned(url(roots)), let root = try? JSONParser.parse(bytes: data),
            let text = root.objectValue?["until"]?.stringValue, let until = Timestamp.parse(text), until > now
        else { return nil }
        return until
    }
}
