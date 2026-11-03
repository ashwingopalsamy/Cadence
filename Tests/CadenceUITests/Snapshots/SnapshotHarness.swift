// The snapshot suite's one way to draw a view and check it against its reference (docs/SPEC.md section 14.4).
//
//   make snapshots-check   compares every render with docs/snapshots/suite and fails on a change
//   make snapshots         records every render as the new reference (CADENCE_RECORD_SNAPSHOTS=1)
//
// Every render is the same on every day and in every locale, time zone and appearance of the Mac it runs on: the colour
// scheme, locale, calendar, time zone and text size are set in the view's environment, the macOS appearance is set
// around the draw, animations are off, the main loop never runs while a view is drawn (so no gesture is halfway and
// no field has focus), and the fixtures take their clock and zone from the example day. What a Mac's accessibility
// display settings do to a view cannot be set per view, so SnapshotHarnessTests checks that they are off. The
// comparison tolerance is SnapshotTolerance.standard.
import AppKit
import SwiftUI
import Testing

@testable import CadenceUI

/// Every snapshot suite is nested in this one, so its tests run one at a time: they share the main thread and the
/// fixture folders under the temporary directory.
@Suite("Snapshots", .serialized) enum Snapshots {}

/// A test argument that prints as its name, so a log line for 49 poses is not 49 dumps of a struct.
struct Named<Value: Sendable>: Sendable, CustomTestStringConvertible {
    let name: String
    let value: Value

    var testDescription: String { name }
}

/// A theme a snapshot is taken in.
enum SnapshotTheme: String, CaseIterable, Sendable {
    case light
    case dark

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var appearance: NSAppearance { NSAppearance(named: self == .dark ? .darkAqua : .aqua)! }
}

/// The pixel density of a snapshot: one pixel per point, or two.
enum SnapshotScale: Int, CaseIterable, Sendable {
    case one = 1
    case two = 2

    var label: String { "@\(rawValue)x" }
}

/// How a view is drawn. ImageRenderer draws a text field, a switch or a menu as a yellow placeholder, leaves a
/// ScrollView empty and never runs the layout callbacks a screen sizes itself with, so a view that holds any of those is
/// drawn in a window that is never shown instead. A render that comes out blank or full of placeholders fails.
enum SnapshotPath: Sendable {
    case imageRenderer
    case hosting
}

enum Snapshot {
    // MARK: Where things are

    /// The repository, from this file's place in it.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let references = root.appendingPathComponent("docs/snapshots/suite", isDirectory: true)
    static let entitlements = root.appendingPathComponent("App/Cadence.entitlements")
    static let recordVariable = "CADENCE_RECORD_SNAPSHOTS"

    /// A run that records new references instead of comparing.
    static var isRecording: Bool { ProcessInfo.processInfo.environment[recordVariable] == "1" }

    static func reference(_ surface: String, _ name: String, _ theme: SnapshotTheme, _ scale: SnapshotScale) -> URL {
        references.appendingPathComponent(surface, isDirectory: true)
            .appendingPathComponent("\(name)-\(theme.rawValue)\(scale.label).png")
    }

    /// Where a failed render, and the picture of what moved, are written.
    static let failures = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-snapshot-failures", isDirectory: true)

    // MARK: The fixed environment

    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    static let locale = Locale(identifier: "en_GB")
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        return calendar
    }()

    /// The bundled figure face, registered once so no render falls back to the system mono.
    static let fonts: Bool = CadenceType.registerFonts(in: root.appendingPathComponent("App/Resources/Fonts"))

    /// A scratch folder for one fixture. Whoever builds the fixture clears it first, so a run starts from nothing.
    static func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cadence-snapshots-\(name)", isDirectory: true)
    }

    /// A file name for a state, a pane or a pose: "Wrap-up due" is `wrap-up-due`. A camel-case pose name such as
    /// "twoMugs" is split at its capitals with `camelCase`, which gives `two-mugs`.
    static func slug(_ text: String, camelCase: Bool = false) -> String {
        var out = ""
        for character in text {
            if camelCase, character.isUppercase, let last = out.last, last != "-" { out.append("-") }
            if character.isLetter || character.isNumber {
                out.append(contentsOf: character.lowercased())
            } else if let last = out.last, last != "-" {
                out.append("-")
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private struct Pinned<Content: View>: View {
        let theme: SnapshotTheme
        let margin: CGFloat
        let content: Content

        var body: some View {
            content
                .padding(margin)
                .background(CadenceColor.canvas.color)
                .environment(\.colorScheme, theme.colorScheme)
                .environment(\.locale, Snapshot.locale)
                .environment(\.calendar, Snapshot.calendar)
                .environment(\.timeZone, Snapshot.zone)
                .environment(\.layoutDirection, .leftToRight)
                .environment(\.legibilityWeight, .regular)
                .dynamicTypeSize(.large)
                .transaction {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
        }
    }

    // MARK: Drawing

    /// Draws `content` in a theme at the given scales, on the window's canvas with `margin` around it. Nil for a scale
    /// that could not be drawn.
    @MainActor
    static func render<V: View>(
        _ content: V, theme: SnapshotTheme, scales: [SnapshotScale], path: SnapshotPath, margin: CGFloat
    ) -> [SnapshotScale: SnapshotBitmap] {
        _ = fonts
        let pinned = Pinned(theme: theme, margin: margin, content: content)
        switch path {
        case .imageRenderer: return viaImageRenderer(pinned, theme: theme, scales: scales)
        case .hosting: return viaHosting(pinned, theme: theme, scales: scales)
        }
    }

    @MainActor
    private static func viaImageRenderer<V: View>(_ view: V, theme: SnapshotTheme, scales: [SnapshotScale]) -> [SnapshotScale: SnapshotBitmap] {
        let renderer = ImageRenderer(content: view)
        renderer.isOpaque = true
        var out: [SnapshotScale: SnapshotBitmap] = [:]
        for scale in scales {
            renderer.scale = CGFloat(scale.rawValue)
            // Colours that read the macOS appearance while they draw (NSColor.setFill) read this theme's.
            var image: CGImage?
            theme.appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            if let image, let bitmap = SnapshotBitmap(image) { out[scale] = bitmap }
        }
        return out
    }

    @MainActor
    private static func viaHosting<V: View>(_ view: V, theme: SnapshotTheme, scales: [SnapshotScale]) -> [SnapshotScale: SnapshotBitmap] {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = theme.appearance
        hosting.safeAreaRegions = []
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = theme.appearance
        window.contentView = hosting

        func fit() -> CGSize {
            let fitting = hosting.fittingSize
            let size = CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
            window.setContentSize(size)
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            return size
        }
        // The main loop never runs here, so no `.task` starts: Tempo is its held pose, no gesture is halfway, no field has
        // taken focus and no animation has begun. That is the state the screen rests in, and it is the same on every run.
        // A few layout passes take the view to its final size and position.
        _ = fit()
        for _ in 0..<3 {
            hosting.updateConstraintsForSubtreeIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }
        let size = fit()
        var out: [SnapshotScale: SnapshotBitmap] = [:]
        for scale in scales {
            guard
                let blank = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale.rawValue, pixelsHigh: Int(size.height) * scale.rawValue,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0),
                let rep = blank.retagging(with: .sRGB)
            else { continue }
            rep.size = size
            theme.appearance.performAsCurrentDrawingAppearance {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
            }
            if let image = rep.cgImage, let bitmap = SnapshotBitmap(image) { out[scale] = bitmap }
        }
        window.contentView = nil
        return out
    }

    // MARK: Checking

    /// Draws `content` in light and dark at each scale and checks every render against its reference, or records it.
    /// `margin` is the canvas left around the content, so a shadow is not cut off.
    @MainActor
    static func check<V: View>(
        _ surface: String, _ name: String, path: SnapshotPath = .imageRenderer, margin: CGFloat = CadenceSpace.s16,
        scales: [SnapshotScale] = SnapshotScale.allCases, sourceLocation: SourceLocation = #_sourceLocation,
        @ViewBuilder _ content: () -> V
    ) {
        #expect(fonts, "the bundled font did not register", sourceLocation: sourceLocation)
        for theme in SnapshotTheme.allCases {
            let rendered = render(content(), theme: theme, scales: scales, path: path, margin: margin)
            for scale in scales {
                let file = reference(surface, name, theme, scale)
                guard let bitmap = rendered[scale] else {
                    Issue.record("\(surface)/\(name) \(theme.rawValue)\(scale.label): the view could not be drawn", sourceLocation: sourceLocation)
                    continue
                }
                if bitmap.inkedShare < blankLimit {
                    Issue.record(
                        "\(surface)/\(name) \(theme.rawValue)\(scale.label): the render is blank. Draw this view with path: .hosting.",
                        sourceLocation: sourceLocation)
                    continue
                }
                if path == .imageRenderer, bitmap.placeholderPixels > placeholderLimit {
                    Issue.record(
                        "\(surface)/\(name) \(theme.rawValue)\(scale.label): ImageRenderer drew a control as its yellow placeholder. Draw this view with path: .hosting.",
                        sourceLocation: sourceLocation)
                    continue
                }
                verify(bitmap, against: file, surface: surface, sourceLocation: sourceLocation)
            }
        }
    }

    /// A render with a smaller share of its pixels off the canvas than this drew nothing.
    static let blankLimit = 0.005

    /// More of the placeholder's yellow than this, and the view holds a control ImageRenderer cannot draw.
    static let placeholderLimit = 100

    /// Records the render, or compares it. Returns whether the render is the reference, within the tolerance.
    @discardableResult
    static func verify(
        _ bitmap: SnapshotBitmap, against file: URL, surface: String, recording: Bool = isRecording,
        tolerance: SnapshotTolerance = .standard, failuresIn folder: URL = failures, sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        if recording {
            guard let png = bitmap.png() else {
                Issue.record("\(file.lastPathComponent): could not encode the PNG", sourceLocation: sourceLocation)
                return false
            }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: file)
            } catch {
                Issue.record("\(file.path): could not write the reference: \(error)", sourceLocation: sourceLocation)
                return false
            }
            return true
        }
        guard let stored = try? Data(contentsOf: file) else {
            Issue.record("\(surface)/\(file.lastPathComponent): no reference at \(file.path). Run make snapshots.", sourceLocation: sourceLocation)
            return false
        }
        guard let reference = SnapshotBitmap(png: stored) else {
            Issue.record("\(surface)/\(file.lastPathComponent): the reference is not a readable PNG. Run make snapshots.", sourceLocation: sourceLocation)
            return false
        }
        let outcome = SnapshotComparison.compare(bitmap, to: reference, tolerance: tolerance)
        if outcome.isMatch { return true }

        let base = file.deletingPathExtension().lastPathComponent
        let out = folder.appendingPathComponent(surface, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let actualFile = out.appendingPathComponent("\(base)-actual.png")
        let diffFile = out.appendingPathComponent("\(base)-diff.png")
        try? bitmap.png()?.write(to: actualFile)
        var written = "actual: \(actualFile.path)"
        if let diff = SnapshotComparison.diff(bitmap, reference, tolerance: tolerance), (try? diff.png()?.write(to: diffFile)) != nil {
            written += "\n  diff: \(diffFile.path)"
        }
        written += "\n  reference: \(file.path)"
        let what: String
        switch outcome {
        case .sizeMismatch(let actual, let expected): what = "the size is \(actual), the reference is \(expected)"
        case .differs(let differing, let total, let worst):
            let share = String(format: "%.3f", Double(differing) / Double(total) * 100)
            what = "\(differing) of \(total) pixels differ (\(share)%, the most allowed is \(tolerance.fraction * 100)% beyond \(tolerance.channel) of 255); worst channel step \(worst)"
        case .match: what = ""
        }
        Issue.record(
            "\(surface)/\(base): \(what)\n  \(written)\n  If the change is meant, run make snapshots and commit the new references.",
            sourceLocation: sourceLocation)
        return false
    }
}
