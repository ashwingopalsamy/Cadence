// Every state of the menu-bar mark at 4x on the sheet's bar and at true size on a light and a dark bar, with its
// name, then the same under Increase Contrast. Drawn offscreen, so it needs no window.
import AppKit
import CadenceUI

enum MarkSheet {
    private enum Layout {
        static let scale: CGFloat = 2
        static let columns = 6
        static let cellWidth: CGFloat = 180
        static let zoom: CGFloat = 4
        static let tile = CadenceMarkTokens.side * zoom + CadenceSpace.s16
        static let chipWidth = CadenceMarkTokens.side + CadenceSpace.s16
        static let chipHeight = CadenceMarkTokens.side + CadenceSpace.s8
        static let labelHeight = CadenceSpace.s20
        static var cellHeight: CGFloat { tile + CadenceSpace.s4 + labelHeight }
    }

    /// Writes the sheet for the light or the dark bar. Returns false when the PNG could not be written.
    @MainActor static func write(dark: Bool, to path: String) -> Bool {
        let sections: [(title: String, specimens: [MarkSpecimen], contrast: Bool)] = [
            ("Standard", MarkSpecimen.all, false),
            ("Increase Contrast", MarkSpecimen.all, true),
            ("Nothing resolved yet: the water is a meniscus", MarkSpecimen.empty, false),
        ]
        func grid(_ count: Int) -> CGFloat {
            let rows = (count + Layout.columns - 1) / Layout.columns
            return CGFloat(rows) * Layout.cellHeight + CGFloat(rows - 1) * CadenceSpace.s8
        }
        let pad = CadenceSpace.s24
        let gap = CadenceSpace.s8
        let titleHeight = CadenceType.section.lineHeight
        let sectionLabel = CadenceType.label.lineHeight
        let width = pad * 2 + CGFloat(Layout.columns) * Layout.cellWidth + CGFloat(Layout.columns - 1) * gap
        let height = pad * 2 + titleHeight + sections.reduce(0) { $0 + CadenceSpace.s16 + sectionLabel + gap + grid($1.specimens.count) }

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(width * Layout.scale), pixelsHigh: Int(height * Layout.scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let bitmap = NSGraphicsContext(bitmapImageRep: rep)
        else { return false }
        rep.size = NSSize(width: width, height: height)
        let c = bitmap.cgContext
        c.translateBy(x: 0, y: height * Layout.scale)
        c.scaleBy(x: Layout.scale, y: -Layout.scale)

        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        appearance.performAsCurrentDrawingAppearance {
            c.setFillColor(CadenceColor.canvas.nsColor.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            text("Menu-bar mark, every state, \(dark ? "dark" : "light") bar", CadenceType.section, CadenceColor.ink, at: CGPoint(x: pad, y: pad))

            var y = pad + titleHeight
            for (title, specimens, contrast) in sections {
                y += CadenceSpace.s16
                text(title, CadenceType.label, CadenceColor.ink3, at: CGPoint(x: pad, y: y))
                y += sectionLabel + gap
                let own = MarkBar(appearance: appearance, increaseContrast: contrast)
                let light = MarkBar(appearance: NSAppearance(named: .aqua)!, increaseContrast: contrast)
                let darkBar = MarkBar(appearance: NSAppearance(named: .darkAqua)!, increaseContrast: contrast)
                for (index, specimen) in specimens.enumerated() {
                    let origin = CGPoint(
                        x: pad + CGFloat(index % Layout.columns) * (Layout.cellWidth + gap),
                        y: y + CGFloat(index / Layout.columns) * (Layout.cellHeight + gap))
                    cell(specimen, at: origin, own: own, light: light, dark: darkBar, in: c)
                }
                y += grid(specimens.count)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    private static func cell(_ specimen: MarkSpecimen, at origin: CGPoint, own: MarkBar, light: MarkBar, dark: MarkBar, in c: CGContext) {
        let tile = CGRect(origin: origin, size: CGSize(width: Layout.tile, height: Layout.tile))
        ground(own, tile, in: c)
        mark(specimen.form, bar: own, at: CGPoint(x: tile.midX, y: tile.midY), zoom: Layout.zoom, in: c)

        let chipX = tile.maxX + CadenceSpace.s12
        for (row, bar) in [light, dark].enumerated() {
            let chip = CGRect(
                x: chipX, y: tile.minY + CGFloat(row) * (Layout.chipHeight + CadenceSpace.s8),
                width: Layout.chipWidth, height: Layout.chipHeight)
            ground(bar, chip, in: c)
            mark(specimen.form, bar: bar, at: CGPoint(x: chip.midX, y: chip.midY), zoom: 1, in: c)
        }
        text(specimen.name, CadenceType.comparison, CadenceColor.ink2, at: CGPoint(x: origin.x, y: tile.maxY + CadenceSpace.s4))
    }

    private static func ground(_ bar: MarkBar, _ rect: CGRect, in c: CGContext) {
        let reference = bar.palette.reference
        c.setFillColor(ColorTokenHex.cgColor(reference))
        c.addPath(CGPath(roundedRect: rect, cornerWidth: CadenceRadius.small, cornerHeight: CadenceRadius.small, transform: nil))
        c.fillPath()
    }

    private static func mark(_ form: MarkForm, bar: MarkBar, at centre: CGPoint, zoom: CGFloat, in c: CGContext) {
        let side = CadenceMarkTokens.side * zoom
        c.saveGState()
        c.translateBy(x: centre.x - side / 2, y: centre.y - side / 2)
        c.scaleBy(x: zoom, y: zoom)
        MarkRenderer.draw(form, bar: bar, in: c)
        c.restoreGState()
    }

    private static func text(_ string: String, _ type: TypeToken, _ color: ColorToken, at point: CGPoint) {
        NSAttributedString(string: string, attributes: [.font: type.nsFont, .foregroundColor: color.nsColor]).draw(at: point)
    }
}

/// The bar references are `#rrggbb` strings.
private enum ColorTokenHex {
    static func cgColor(_ hex: String) -> CGColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        func channel(_ shift: UInt32) -> CGFloat { CGFloat((value >> shift) & 0xff) / 255 }
        return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }
}
