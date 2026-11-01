// S4 spike app: sample idle time twice 3 s apart and log workspace and session notifications.
// Args: --log PATH [--watch SECONDS]. Without --watch it exits after the second sample.
import AppKit
import CoreGraphics

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
// A global, not a guard binding: newer Swift treats top-level guard bindings as locals that closures and C
// callbacks cannot capture.
let logPath = required("--log")
func log(_ s: String) {
    let data = Data((s + "\n").utf8)
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: logPath))
    }
}

// kCGAnyInputEventType is 0xFFFFFFFF; .null is kCGEventNull (0). Both are sampled for the record.
let anyInput = CGEventType(rawValue: ~0)!
func idle(_ t: CGEventType) -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: t)
}

let ws = NSWorkspace.shared.notificationCenter
let names: [Notification.Name] = [
    NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
    NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
    NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
]
var tokens: [NSObjectProtocol] = []
for n in names {
    tokens.append(ws.addObserver(forName: n, object: nil, queue: .main) { _ in log("event=\(n.rawValue)") })
}
for n in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
    tokens.append(DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name(n), object: nil, queue: .main) { _ in log("event=\(n)") })
}
log("subscribed=\(names.count + 2)")

let watch = arg("--watch").flatMap(Double.init)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// The first sample waits a second, so the key that started the run is not counted.
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    log("null_a=\(idle(.null))")
    log("any_a=\(idle(anyInput))")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
    log("null_b=\(idle(.null))")
    log("any_b=\(idle(anyInput))")
    // Per kind, so an input that keeps "any input" low can be named.
    let kinds: [(String, CGEventType)] = [
        ("mouse", .mouseMoved), ("key", .keyDown), ("flags", .flagsChanged), ("scroll", .scrollWheel),
        ("click", .leftMouseDown), ("tablet", .tabletProximity),
    ]
    for (label, kind) in kinds { log("kind_\(label)=\(idle(kind))") }
    if watch == nil { exit(0) }
}
if let w = watch { DispatchQueue.main.asyncAfter(deadline: .now() + w) { exit(0) } }
app.run()
