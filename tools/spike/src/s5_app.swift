// S5 spike app: register Ctrl+Opt+K with Carbon and log the press. Arg: --log PATH. Exits after 18 s.
import AppKit
import Carbon.HIToolbox

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

var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
    log("pressed")
    exit(0)
}, 1, &spec, nil, nil)

var ref: EventHotKeyRef?
let id = EventHotKeyID(signature: OSType(0x4344_4E43), id: 1)   // "CDNC"
let status = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey), id,
                                 GetApplicationEventTarget(), 0, &ref)
log("handler=\(handlerStatus)")
log("register=\(status)")
if status != 0 { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.asyncAfter(deadline: .now() + 18) { exit(0) }
app.run()
