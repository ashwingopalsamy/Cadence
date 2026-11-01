// CadenceApp: the menu-bar app (macOS only). An accessory app with one running instance.
import AppKit
import CadenceCore
import CadenceUI
import ServiceManagement

// `make uninstall` runs this; it needs no running app and takes no lock.
if CommandLine.arguments.contains("--unregister") {
    let id = Bundle.main.bundleIdentifier ?? ""
    let services = [SMAppService.mainApp, SMAppService.agent(plistName: "\(id).agent.plist")]
    var failed = false
    // A service never registered reports notFound, and unregistering it throws.
    for service in services {
        if service.status == .enabled || service.status == .requiresApproval {
            do {
                try service.unregister()
            } catch {
                FileHandle.standardError.write(Data("unregister: \(error.localizedDescription)\n".utf8))
                failed = true
            }
        }
        print("unregister: status \(service.status.rawValue)")
    }
    exit(failed ? 1 : 0)
}

// flock guards the inode, so the file sits in Application Support, which nothing purges, not in tmp.
// The kernel drops the lock when the process ends, however it ends, so a crash cannot strand it.
// The descriptor stays open for the life of the process. Only a held lock stops a launch; any other
// failure runs without one, because a missing lock is better than a menu-bar app that will not start.
let lockDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
let lockDescriptor = open(lockDirectory.appendingPathComponent("cadence.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
if lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK {
    if let id = Bundle.main.bundleIdentifier {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        others.first { $0 != .current }?.activate()
    }
    FileHandle.standardError.write(Data("Cadence is already running; quit it first.\n".utf8))
    exit(1)
}

if let resources = Bundle.main.resourceURL {
    CadenceType.registerFonts(in: resources.appendingPathComponent("Fonts"))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
