// The snapshot harness itself: the comparison tolerance, what a missing or changed reference reports, and that a render
// is the same picture twice and does not depend on the machine's display settings. These never touch docs/snapshots.
import AppKit
import SwiftUI
import Testing

@testable import CadenceUI

/// Collects the messages of issues a test expects, so what a failure says can be checked.
private final class Messages: @unchecked Sendable {
    var all: [String] = []
}

extension Snapshots {
    @Suite("the harness") struct Harness {
        static func solid(_ width: Int, _ height: Int, _ gray: UInt8) -> SnapshotBitmap {
            var pixels = [UInt8](repeating: gray, count: width * height * 4)
            for pixel in 0..<(width * height) { pixels[pixel * 4 + 3] = 255 }
            return SnapshotBitmap(width: width, height: height, pixels: pixels)
        }

        /// `solid`, with the first `count` pixels moved by `step` in every colour channel.
        static func moved(_ base: SnapshotBitmap, pixels count: Int, by step: Int) -> SnapshotBitmap {
            var out = base
            for pixel in 0..<count {
                for channel in 0..<3 { out.pixels[pixel * 4 + channel] = UInt8(Int(out.pixels[pixel * 4 + channel]) + step) }
            }
            return out
        }

        static func scratch() -> URL {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-harness-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        // MARK: The tolerance

        @Test func theToleranceIsHalfAPercentOfPixelsBeyondEightOf255() {
            #expect(SnapshotTolerance.standard == SnapshotTolerance(channel: 8, fraction: 0.005))
        }

        @Test func identicalImagesMatchAtOnce() {
            let image = Self.solid(40, 25, 100)
            #expect(SnapshotComparison.compare(image, to: image) == .match(differing: 0))
        }

        @Test func everyPixelMovedByEightStillMatches() {
            let base = Self.solid(40, 25, 100)
            #expect(SnapshotComparison.compare(Self.moved(base, pixels: 1000, by: 8), to: base).isMatch)
        }

        @Test func halfAPercentOfPixelsMovedByNineMatchesAndOneMoreFails() {
            let base = Self.solid(100, 200, 100)  // 20 000 pixels, so 100 may differ
            #expect(SnapshotComparison.compare(Self.moved(base, pixels: 100, by: 9), to: base) == .match(differing: 100))
            let over = SnapshotComparison.compare(Self.moved(base, pixels: 101, by: 9), to: base)
            #expect(over == .differs(differing: 101, total: 20_000, worst: 9))
        }

        @Test func aMovedBlockFails() {
            let base = Self.solid(100, 100, 30)
            let outcome = SnapshotComparison.compare(Self.moved(base, pixels: 500, by: 120), to: base)
            #expect(outcome == .differs(differing: 500, total: 10_000, worst: 120))
        }

        @Test func aChangedAlphaCounts() {
            let base = Self.solid(10, 10, 200)
            var clear = base
            for pixel in 0..<50 { clear.pixels[pixel * 4 + 3] = 0 }
            #expect(!SnapshotComparison.compare(clear, to: base).isMatch)
        }

        @Test func aDifferentSizeFailsWhateverThePixels() {
            let outcome = SnapshotComparison.compare(Self.solid(10, 10, 5), to: Self.solid(10, 11, 5))
            #expect(outcome == .sizeMismatch(actual: "10 x 10", reference: "10 x 11"))
        }

        @Test func anOddPixelCountIsComparedToo() {
            let base = Self.solid(3, 3, 10)
            var last = base
            last.pixels[8 * 4] = 200
            #expect(SnapshotComparison.compare(last, to: base, tolerance: SnapshotTolerance(channel: 8, fraction: 0)) == .differs(differing: 1, total: 9, worst: 190))
        }

        // MARK: Reading and writing

        @Test func aPNGReadsBackToTheSamePixels() throws {
            var image = Self.solid(33, 21, 90)
            image.pixels[4 * 5] = 250
            let png = try #require(image.png())
            #expect(SnapshotBitmap(png: png) == image)
        }

        @Test func anOpaqueImageIsStoredWithoutAnAlphaChannel() throws {
            let opaque = try #require(Self.solid(8, 8, 90).png())
            var clear = Self.solid(8, 8, 90)
            clear.pixels[3] = 0
            let translucent = try #require(clear.png())
            // The colour type is the 10th byte of the IHDR chunk: 2 is RGB, 6 is RGB with alpha.
            #expect(opaque[25] == 2)
            #expect(translucent[25] == 6)
        }

        // MARK: What a check reports

        @Test func recordingWritesAReferenceThatThenMatches() throws {
            let folder = Self.scratch()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("surface/name-light@1x.png")
            let image = Self.solid(30, 20, 77)
            #expect(Snapshot.verify(image, against: file, surface: "surface", recording: true))
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(Snapshot.verify(image, against: file, surface: "surface", recording: false))
        }

        @Test func aMissingReferenceFailsAndSaysHowToRecordIt() {
            let folder = Self.scratch()
            defer { try? FileManager.default.removeItem(at: folder) }
            let messages = Messages()
            withKnownIssue {
                Snapshot.verify(Self.solid(5, 5, 1), against: folder.appendingPathComponent("none-dark@2x.png"), surface: "surface", recording: false)
            } matching: { issue in
                messages.all.append("\(issue.comments.map { "\($0)" }.joined(separator: " "))")
                return true
            }
            #expect(messages.all.count == 1)
            #expect(messages.all.first?.contains("Run make snapshots") == true)
        }

        @Test func aChangedRenderFailsAndWritesTheActualAndTheDiff() throws {
            let folder = Self.scratch()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("refs/name-dark@2x.png")
            let reference = Self.solid(100, 100, 40)
            Snapshot.verify(reference, against: file, surface: "surface", recording: true)
            let changed = Self.moved(reference, pixels: 900, by: 90)

            let failures = folder.appendingPathComponent("failures", isDirectory: true)
            let messages = Messages()
            withKnownIssue {
                Snapshot.verify(changed, against: file, surface: "surface", recording: false, failuresIn: failures)
            } matching: { issue in
                messages.all.append("\(issue.comments.map { "\($0)" }.joined(separator: " "))")
                return true
            }
            let actual = failures.appendingPathComponent("surface/name-dark@2x-actual.png")
            let diff = failures.appendingPathComponent("surface/name-dark@2x-diff.png")
            #expect(FileManager.default.fileExists(atPath: actual.path))
            #expect(FileManager.default.fileExists(atPath: diff.path))
            let message = try #require(messages.all.first)
            #expect(message.contains(actual.path) && message.contains(diff.path), "the message names both files")
            #expect(message.contains("900 of 10000 pixels differ"))
            #expect(SnapshotBitmap(png: try Data(contentsOf: actual)) == changed)
        }

        @Test func referencesLiveBySurfaceNameThemeAndScale() {
            let file = Snapshot.reference("today", "in-rhythm-full", .dark, .two)
            #expect(file.path.hasSuffix("docs/snapshots/suite/today/in-rhythm-full-dark@2x.png"))
            #expect(Snapshot.reference("marks", "sealed", .light, .one).lastPathComponent == "sealed-light@1x.png")
            #expect(Snapshot.slug("Wrap-up due") == "wrap-up-due")
            #expect(Snapshot.slug("GitHub") == "github")
            #expect(Snapshot.slug("twoMugs", camelCase: true) == "two-mugs")
        }

        // MARK: The same on every run and machine

        @MainActor @Test func aRenderIsTheSamePictureTwice() throws {
            let tight = SnapshotTolerance(channel: 8, fraction: 0)
            for path in [SnapshotPath.imageRenderer, .hosting] {
                let view = { TempoCanvas(spec: TempoSpec(pose: .walk), elapsed: nil).frame(width: 96, height: TempoView.height(forWidth: 96)) }
                let first = Snapshot.render(view(), theme: .dark, scales: [.two], path: path, margin: 24)[.two]
                let second = Snapshot.render(view(), theme: .dark, scales: [.two], path: path, margin: 24)[.two]
                let a = try #require(first), b = try #require(second)
                #expect(SnapshotComparison.compare(a, to: b, tolerance: tight).isMatch, "\(path)")
            }
        }

        @MainActor @Test func theThemeSetsTheColoursWhateverTheMachineIsSetTo() throws {
            let probe = Color(nsColor: CadenceColor.canvas.nsColor).frame(width: 4, height: 4)
            for path in [SnapshotPath.imageRenderer, .hosting] {
                let light = try #require(Snapshot.render(probe, theme: .light, scales: [.one], path: path, margin: 0)[.one])
                let dark = try #require(Snapshot.render(probe, theme: .dark, scales: [.one], path: path, margin: 0)[.one])
                #expect(Array(light.pixels[0..<3]) == [0xF2, 0xF1, 0xF7], "\(path) light canvas")
                #expect(Array(dark.pixels[0..<3]) == [0x10, 0x0E, 0x17], "\(path) dark canvas")
            }
        }

        /// A Mac set to Reduce Motion, Reduce Transparency, Increase Contrast, Differentiate Without Colour or Invert
        /// Colours draws every view differently, and SwiftUI offers no way to set these per view. The references were
        /// recorded with all five off.
        @MainActor @Test func theMachineShowsItsDefaultDisplaySettings() {
            let workspace = NSWorkspace.shared
            let on = [
                ("Reduce Motion", workspace.accessibilityDisplayShouldReduceMotion),
                ("Reduce Transparency", workspace.accessibilityDisplayShouldReduceTransparency),
                ("Increase Contrast", workspace.accessibilityDisplayShouldIncreaseContrast),
                ("Differentiate Without Colour", workspace.accessibilityDisplayShouldDifferentiateWithoutColor),
                ("Invert Colours", workspace.accessibilityDisplayShouldInvertColors),
            ].filter(\.1).map(\.0)
            #expect(on.isEmpty, "Turn off \(on.joined(separator: ", ")) in System Settings, Accessibility, Display, to run the snapshots.")
        }

        @MainActor @Test func imageRendererDrawsATextFieldAsAPlaceholderSoTheHostedPathExists() throws {
            let field = TextField("Log something", text: .constant("")).frame(width: 240, height: 28)
            let drawn = try #require(Snapshot.render(field, theme: .light, scales: [.one], path: .imageRenderer, margin: 8)[.one])
            let hosted = try #require(Snapshot.render(field, theme: .light, scales: [.one], path: .hosting, margin: 8)[.one])
            #expect(drawn.placeholderPixels > Snapshot.placeholderLimit)
            #expect(hosted.placeholderPixels == 0)
        }
    }
}
