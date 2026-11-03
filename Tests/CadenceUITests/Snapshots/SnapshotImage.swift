// Pixels for the snapshot suite: a render normalised to 8-bit sRGB, the PNG it is stored as, and the comparison that
// tells a real change from antialiasing jitter. Nothing here draws a view; SnapshotHarness does that.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image as 8-bit sRGB RGBA, premultiplied, rows top to bottom. Two images compare byte for byte after this, so a
/// reference stored by one machine reads the same on another whatever colour space either side drew in.
struct SnapshotBitmap: Equatable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(_ image: CGImage) {
        guard image.width > 0, image.height > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: image.width, height: image.height, pixels: pixels)
    }

    init?(png data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        self.init(image)
    }

    /// The pixels one 32-bit word each, red in the lowest byte on a little-endian machine. The loops below read them
    /// this way because the suite runs in debug builds, where a loop over every channel of a 2400 pixel wide image is slow.
    private func words<T>(_ body: (UnsafeBufferPointer<UInt32>) -> T) -> T {
        pixels.withUnsafeBytes { body($0.bindMemory(to: UInt32.self)) }
    }

    var isOpaque: Bool {
        words { all in
            for word in all where word >> 24 != 0xff { return false }
            return true
        }
    }

    /// Pixels in the exact yellow ImageRenderer fills a control it cannot draw with (a text field, a switch, a menu).
    var placeholderPixels: Int {
        let yellow = UInt32(0xff) | UInt32(204) << 8 | UInt32(0) << 16 | UInt32(0xff) << 24
        return words { all in
            var count = 0
            for word in all where word == yellow { count += 1 }
            return count
        }
    }

    /// The share of pixels that are not the corner pixel's colour, which is the canvas around the content. A view that
    /// drew nothing, as ImageRenderer does for some containers, leaves a flat image and scores zero.
    var inkedShare: Double {
        words { all in
            guard let corner = all.first else { return 0 }
            var count = 0
            for word in all where word != corner { count += 1 }
            return Double(count) / Double(all.count)
        }
    }

    /// The PNG the reference is stored as. An opaque image is written without an alpha channel, which keeps the
    /// committed files smaller. Nothing in it depends on the day or the machine, so recording twice writes the same bytes.
    func png() -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let alpha: CGImageAlphaInfo = isOpaque ? .noneSkipLast : .premultipliedLast
        guard
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// How far a render may drift from its reference before the suite calls it a change.
///
/// A pixel differs when any of its channels, alpha included, is more than `channel` out of 255 away from the reference.
/// An image fails when more than `fraction` of its pixels differ, or when its size is not the reference's size. Font
/// antialiasing moves a few edge pixels by a little, which stays well inside this; a moved icon, a changed word or a
/// different colour does not.
struct SnapshotTolerance: Equatable, Sendable {
    var channel: Int
    var fraction: Double

    static let standard = SnapshotTolerance(channel: 8, fraction: 0.005)
}

enum SnapshotOutcome: Equatable {
    case match(differing: Int)
    case sizeMismatch(actual: String, reference: String)
    case differs(differing: Int, total: Int, worst: Int)

    var isMatch: Bool {
        if case .match = self { return true }
        return false
    }
}

enum SnapshotComparison {
    /// How many pixels differ by more than the tolerance, and the largest channel step anywhere.
    static func measure(_ actual: SnapshotBitmap, _ reference: SnapshotBitmap, channel limit: Int) -> (differing: Int, worst: Int) {
        var differing = 0
        var worst = 0
        actual.pixels.withUnsafeBufferPointer { a in
            reference.pixels.withUnsafeBufferPointer { r in
                let pixels = actual.width * actual.height
                // Two pixels at a time, so an image that is mostly the same is skipped at one comparison a word.
                a.baseAddress!.withMemoryRebound(to: UInt64.self, capacity: pixels / 2) { a64 in
                    r.baseAddress!.withMemoryRebound(to: UInt64.self, capacity: pixels / 2) { r64 in
                        for word in 0..<(pixels / 2) where a64[word] != r64[word] {
                            for index in (word * 8)..<(word * 8 + 8) {
                                let step = abs(Int(a[index]) - Int(r[index]))
                                if step > worst { worst = step }
                            }
                            for pixel in (word * 2)..<(word * 2 + 2) {
                                let at = pixel * 4
                                let step = max(
                                    abs(Int(a[at]) - Int(r[at])), abs(Int(a[at + 1]) - Int(r[at + 1])),
                                    abs(Int(a[at + 2]) - Int(r[at + 2])), abs(Int(a[at + 3]) - Int(r[at + 3])))
                                if step > limit { differing += 1 }
                            }
                        }
                        if pixels % 2 == 1 {
                            let at = (pixels - 1) * 4
                            let step = max(
                                abs(Int(a[at]) - Int(r[at])), abs(Int(a[at + 1]) - Int(r[at + 1])),
                                abs(Int(a[at + 2]) - Int(r[at + 2])), abs(Int(a[at + 3]) - Int(r[at + 3])))
                            worst = max(worst, step)
                            if step > limit { differing += 1 }
                        }
                    }
                }
            }
        }
        return (differing, worst)
    }

    static func compare(_ actual: SnapshotBitmap, to reference: SnapshotBitmap, tolerance: SnapshotTolerance = .standard) -> SnapshotOutcome {
        guard actual.width == reference.width, actual.height == reference.height else {
            return .sizeMismatch(actual: "\(actual.width) x \(actual.height)", reference: "\(reference.width) x \(reference.height)")
        }
        let total = actual.width * actual.height
        let (differing, worst) = measure(actual, reference, channel: tolerance.channel)
        let allowed = Int((Double(total) * tolerance.fraction).rounded(.down))
        return differing <= allowed ? .match(differing: differing) : .differs(differing: differing, total: total, worst: worst)
    }

    /// The render with every pixel that differs painted red and the rest dimmed, for a person to see what moved. Both
    /// images must be the same size.
    static func diff(_ actual: SnapshotBitmap, _ reference: SnapshotBitmap, tolerance: SnapshotTolerance = .standard) -> SnapshotBitmap? {
        guard actual.width == reference.width, actual.height == reference.height else { return nil }
        var out = actual.pixels
        for pixel in 0..<(actual.width * actual.height) {
            var delta = 0
            for channel in 0..<4 {
                delta = max(delta, abs(Int(actual.pixels[pixel * 4 + channel]) - Int(reference.pixels[pixel * 4 + channel])))
            }
            if delta > tolerance.channel {
                (out[pixel * 4], out[pixel * 4 + 1], out[pixel * 4 + 2], out[pixel * 4 + 3]) = (255, 0, 64, 255)
            } else {
                for channel in 0..<3 { out[pixel * 4 + channel] = UInt8((Int(out[pixel * 4 + channel]) + 3 * 255) / 4) }
                out[pixel * 4 + 3] = 255
            }
        }
        return SnapshotBitmap(width: actual.width, height: actual.height, pixels: out)
    }
}
