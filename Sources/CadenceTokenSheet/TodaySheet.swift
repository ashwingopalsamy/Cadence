// Today in its main states at the full width, then In rhythm at 680 and compact, on the window's canvas. Drawn offscreen
// in a window that is never shown (T4.1).
import AppKit
import CadenceUI
import SwiftUI

enum TodaySheet {
    private enum Layout {
        static let full: CGFloat = 1200
        static let narrow: CGFloat = 680
        static let compact: CGFloat = 420
        static let columns = 2
    }

    /// Writes the sheet in one theme. Returns false when the PNG could not be written.
    ///
    /// The view is hosted in a window that is never shown and cached to a bitmap, so text fields draw as they do in the
    /// app; ImageRenderer draws them as placeholders.
    @MainActor static func write(dark: Bool, to path: String) -> Bool {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let hosting = NSHostingView(rootView: Sheet(dark: dark))
        hosting.appearance = appearance
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        // One pixel per point keeps the committed file small; the views are the same at any scale.
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    private struct Sheet: View {
        var dark: Bool

        var body: some View {
            let specimens = TodaySpecimen.all
            VStack(alignment: .leading, spacing: CadenceSpace.s24) {
                Text("Today, every main state, \(dark ? "dark" : "light")").cadenceType(CadenceType.section)
                Grid(alignment: .topLeading, horizontalSpacing: CadenceSpace.s24, verticalSpacing: CadenceSpace.s24) {
                    ForEach(Array(stride(from: 0, to: specimens.count, by: Layout.columns)), id: \.self) { start in
                        GridRow(alignment: .top) {
                            ForEach(start..<min(start + Layout.columns, specimens.count), id: \.self) { i in
                                frame(specimens[i], width: Layout.full)
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: CadenceSpace.s24) {
                    frame(TodaySpecimen.inRhythm, width: Layout.narrow, note: "680")
                    frame(TodaySpecimen.inRhythm, width: Layout.compact, note: "compact, 420")
                }
            }
            .padding(CadenceSpace.s32)
            .foregroundStyle(CadenceColor.ink.color)
            .background(CadenceColor.track.color)
        }

        private func frame(_ specimen: TodaySpecimen, width: CGFloat, note: String? = nil) -> some View {
            VStack(alignment: .leading, spacing: CadenceSpace.s8) {
                Text(note.map { "\(specimen.name), \($0)" } ?? specimen.name).cadenceType(CadenceType.label)
                TodayContent(
                    input: specimen.input, contentWidth: width - 2 * CadenceSpace.windowContent, actions: .none
                )
                .padding(CadenceSpace.windowContent)
                .background(CadenceColor.canvas.color)
                .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous))
            }
        }
    }
}
