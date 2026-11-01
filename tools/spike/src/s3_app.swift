// S3 spike app: request authorisation, post one notification with a text-input action,
// append what the user typed to the log. Arg: --log PATH. Gives up after 58 s.
import AppKit
import UserNotifications

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

final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let t = r as? UNTextInputNotificationResponse {
            log("text=" + t.userText.replacingOccurrences(of: "\n", with: " "))
        } else {
            log("action=\(r.actionIdentifier)")
        }
        done()
        exit(0)
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
let center = UNUserNotificationCenter.current()
center.delegate = delegate

center.requestAuthorization(options: [.alert, .sound]) { granted, err in
    if let err = err { log("autherr=" + String(describing: err).replacingOccurrences(of: "\n", with: " ")) }
    guard granted else { log("auth=denied"); exit(0) }
    log("auth=granted")
    let add = UNTextInputNotificationAction(identifier: "ADDLINE", title: "Add a line…", options: [],
                                            textInputButtonTitle: "Add", textInputPlaceholder: "What did you do?")
    let later = UNNotificationAction(identifier: "LATER", title: "In 30 min", options: [])
    center.setNotificationCategories([
        UNNotificationCategory(identifier: "WRAP", actions: [add, later], intentIdentifiers: [], options: [])
    ])
    let content = UNMutableNotificationContent()
    content.title = "Cadence spike"
    content.body = "Choose Add a line… and type something."
    content.categoryIdentifier = "WRAP"
    center.add(UNNotificationRequest(identifier: "spike-s3", content: content, trigger: nil)) { e in
        if let e = e { log("error=post failed: " + String(describing: e)); exit(0) }
        log("posted")
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 58) { log("timeout"); exit(0) }
app.run()
