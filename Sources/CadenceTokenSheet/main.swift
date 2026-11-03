// Developer tool: renders one design sheet in one theme and captures it.
// Usage: CadenceTokenSheet <sheet>-light|<sheet>-dark <output.png>, or light|dark <output.png> for the token sheet.
// Each sheet is one name in `sheetNames` and one case in `sheet`; a new surface adds those and two Makefile lines.
import AppKit
import CadenceUI
import SwiftUI

let arguments = CommandLine.arguments

@MainActor func host(_ view: some View & Sendable) -> NSView {
    let hosting = NSHostingView(rootView: view)
    hosting.safeAreaRegions = []
    return hosting
}

/// The Recap hub and every weekly frame, from the October demo seed (T4.6).
@MainActor func recapSheet() -> NSView {
    do {
        let hub = try RecapSpecimens.seeded()
        let model = RecapModel(loader: FixedRecaps(hub: hub))
        model.reload()
        return host(RecapSheet(hub: hub, model: model))
    } catch {
        FileHandle.standardError.write(Data("recap sheet: \(error)\n".utf8))
        exit(1)
    }
}

/// The Log and the Inbox, read from the October demo seeded into a temporary store (T4.11, T4.7).
@MainActor func logInboxSheet() -> NSView {
    do {
        return host(try LogInboxSheet.make())
    } catch {
        FileHandle.standardError.write(Data("could not seed the log and inbox sheet: \(error)\n".utf8))
        exit(1)
    }
}

/// Insights read from the October demo seed in a throwaway store (T4.2).
@MainActor func insightsSheet() -> NSView {
    guard let sheet = InsightsSheet.make() else {
        FileHandle.standardError.write(Data("could not seed the insights store\n".utf8))
        exit(1)
    }
    return host(sheet)
}

/// The window sheets by name. `marks` is drawn offscreen and handled before the window opens.
let sheetNames = ["tokens", "tempo", "panels", "capture", "sheets", "recaps", "proof", "log", "settings", "firstrun", "insights"]
@MainActor func sheet(_ name: String, dark: Bool) -> NSView {
    switch name {
    case "tempo": host(TempoSheet())
    case "panels": host(PanelSheet())
    case "capture": host(CaptureSheet(dark: dark))
    case "sheets": host(SheetGallery())
    case "recaps": recapSheet()
    case "proof": host(ProofSheet(dark: dark))
    case "log": logInboxSheet()
    case "settings": host(SettingsSheet(dark: dark))
    case "firstrun": host(FirstRunSheet(dark: dark))
    case "insights": insightsSheet()
    default: host(TokenSheet())
    }
}

let mode = arguments.count >= 2 ? arguments[1] : ""
let dark = mode.hasSuffix("dark")
// "light" and "dark" are the token sheet; an old fourth argument ("tempo") still picks a sheet.
let name = mode == "light" || mode == "dark" ? (arguments.count == 4 ? arguments[3] : "tokens") : String(mode.split(separator: "-").first ?? "")
let known = name == "marks" || name == "today" || sheetNames.contains(name)
guard [3, 4].contains(arguments.count), mode.hasSuffix("light") || dark, known else {
    let names = sheetNames + ["marks", "today"]
    FileHandle.standardError.write(
        Data("usage: CadenceTokenSheet light|dark|<sheet>-light|<sheet>-dark <output.png>; sheets: \(names.joined(separator: ", "))\n".utf8))
    exit(2)
}

// Offscreen sheets: drawn without a window.
if name == "marks" || name == "today" {
    if name == "today" { _ = CadenceType.registerFonts(in: URL(fileURLWithPath: "App/Resources/Fonts")) }
    try? FileManager.default.removeItem(atPath: arguments[2])
    let written = MainActor.assumeIsolated {
        name == "marks" ? MarkSheet.write(dark: dark, to: arguments[2]) : TodaySheet.write(dark: dark, to: arguments[2])
    }
    print("\(arguments[2]) \(written ? "offscreen status 0" : "failed")")
    exit(written ? 0 : 1)
}

// `make token-sheet` runs from the repository root.
guard CadenceType.registerFonts(in: URL(fileURLWithPath: "App/Resources/Fonts")) else {
    FileHandle.standardError.write(Data("could not register App/Resources/Fonts\n".utf8))
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let hosting = MainActor.assumeIsolated { sheet(name, dark: dark) }
let window = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
window.contentView = hosting
window.setContentSize(hosting.fittingSize)
window.center()
window.makeKeyAndOrderFront(nil)
// A sheet shows controls at rest, so no field is captured focused.
window.makeFirstResponder(nil)
app.activate()

// screencapture sometimes reports "could not create image from window", so it gets a few tries.
// The old file goes first: a failed run must never leave a stale snapshot behind.
_ = Task { @MainActor in
    try? FileManager.default.removeItem(atPath: arguments[2])
    var status: Int32 = 1
    for _ in 1...5 where status != 0 {
        try? await Task.sleep(for: .seconds(1))
        // A view that settles after layout (wrapped chips, fonts) is captured at its final size.
        window.setContentSize(hosting.fittingSize)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), arguments[2]]
        guard (try? capture.run()) != nil else { continue }
        capture.waitUntilExit()
        status = capture.terminationStatus
    }
    // A locked Mac has no window to capture, so the view is drawn offscreen and the output says so.
    var how = "screencapture"
    if status != 0, let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]),
            (try? png.write(to: URL(fileURLWithPath: arguments[2]))) != nil
        {
            how = "offscreen"
            status = 0
        }
    }
    print("\(arguments[2]) \(Int(window.frame.width))x\(Int(window.frame.height)) \(how) status \(status)")
    exit(status)
}

app.run()
