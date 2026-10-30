// S6 spike listener: wait for a Darwin notification. Args: --log PATH --name NOTIFICATION. Exits after 12 s.
import Foundation

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
guard let logPath = arg("--log"), let name = arg("--name") else { exit(2) }
func log(_ s: String) {
    let data = Data((s + "\n").utf8)
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: logPath))
    }
}

var token: Int32 = 0
let st = notify_register_dispatch(name, &token, DispatchQueue.main) { _ in
    log("received")
    exit(0)
}
log("register=\(st)")
if st != 0 { log("error=notify_register_dispatch failed"); exit(0) }
log("listening")
DispatchQueue.main.asyncAfter(deadline: .now() + 12) { log("timeout"); exit(0) }
dispatchMain()
