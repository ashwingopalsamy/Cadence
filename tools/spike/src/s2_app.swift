// S2 spike app: register or unregister the main app and a bundled agent.
// Args: --cmd register|unregister --plist NAME --log PATH. With --agent it just exits.
import Foundation
import ServiceManagement

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func name(_ s: SMAppService.Status) -> String {
    switch s {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown"
    }
}
func oneLine(_ e: Error) -> String {
    String(describing: e).replacingOccurrences(of: "\n", with: " ")
}

if CommandLine.arguments.contains("--agent") { exit(0) }
guard let cmd = arg("--cmd"), let plist = arg("--plist"), let logPath = arg("--log") else { exit(2) }

let mainApp = SMAppService.mainApp
let agent = SMAppService.agent(plistName: plist)
var out = ""
do { if cmd == "register" { try mainApp.register() } else { try mainApp.unregister() } }
catch { out += "mainerr=\(oneLine(error))\n" }
do { if cmd == "register" { try agent.register() } else { try agent.unregister() } }
catch { out += "agenterr=\(oneLine(error))\n" }
out += "main=\(name(mainApp.status))\nagent=\(name(agent.status))\n"
try? out.write(toFile: logPath, atomically: true, encoding: .utf8)
