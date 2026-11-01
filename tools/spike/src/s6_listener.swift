// S6 spike listener: wait for a Darwin notification (CFNotificationCenter's Darwin center). Args: --log PATH --name NOTIFICATION. Exits after 12 s.
import Foundation

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
/// A required argument; the spike exits 2 without it.
func required(_ name: String) -> String {
    guard let value = arg(name) else { exit(2) }
    return value
}
// Globals, not guard bindings, so the C callback below captures nothing.
let logPath = required("--log")
let name = required("--name")
func log(_ s: String) {
    let data = Data((s + "\n").utf8)
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: logPath))
    }
}

// The Darwin notify center through CoreFoundation: the same notifications as notify(3), and its module is
// always visible to Swift, unlike notify.h.
let center = CFNotificationCenterGetDarwinNotifyCenter()
CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
    log("received")
    exit(0)
}, name as CFString, nil, .deliverImmediately)
log("register=0")
log("listening")
DispatchQueue.main.asyncAfter(deadline: .now() + 12) { log("timeout"); exit(0) }
dispatchMain()
