// Developer tool: shows the token sheet in one theme and captures the window with screencapture.
// Usage: CadenceTokenSheet light|dark <output.png>
import AppKit
import CadenceUI
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 3, ["light", "dark"].contains(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: CadenceTokenSheet light|dark <output.png>\n".utf8))
    exit(2)
}

// `make token-sheet` runs from the repository root.
guard CadenceType.registerFonts(in: URL(fileURLWithPath: "App/Resources/Fonts")) else {
    FileHandle.standardError.write(Data("could not register App/Resources/Fonts\n".utf8))
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let hosting = NSHostingView(rootView: TokenSheet())
let window = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.appearance = NSAppearance(named: arguments[1] == "dark" ? .darkAqua : .aqua)
window.contentView = hosting
window.setContentSize(hosting.fittingSize)
window.center()
window.makeKeyAndOrderFront(nil)
app.activate()

// screencapture sometimes reports "could not create image from window", so it gets a few tries.
// The old file goes first: a failed run must never leave a stale snapshot behind.
_ = Task { @MainActor in
    try? FileManager.default.removeItem(atPath: arguments[2])
    var status: Int32 = 1
    for _ in 1...5 where status != 0 {
        try? await Task.sleep(for: .seconds(1))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), arguments[2]]
        guard (try? capture.run()) != nil else { continue }
        capture.waitUntilExit()
        status = capture.terminationStatus
    }
    print("\(arguments[2]) \(Int(window.frame.width))x\(Int(window.frame.height)) status \(status)")
    exit(status)
}

app.run()
