// Tempo's props, from the prototype's `TP`. Hand props are drawn at the hand point; the rest sit on the glass or in
// front of it at their own coordinates. Flat colours, no outlines.
import SwiftUI

private typealias T = CadenceTempoTokens
private typealias P = CadenceTempoTokens.Prop

enum TempoProps {
    static func draw(_ prop: TempoPose.Prop, at point: CGPoint, _ ink: Ink) {
        let (x, y) = (point.x, point.y)
        let k = T.ink
        switch prop {
        // In a hand
        case .bell:
            ink.rect(x - 1.6, y - 1, 3.2, 7, 1.4, P.wood)
            ink.fill("M\(x) \(y + 4)c4.4 0 6.4 3.2 6.4 7v3.4l2 2.4h-16.8l2-2.4v-3.4c0-3.8 2-7 6.4-7z", T.sun)
            ink.circle(x, y + 18.4, 2, k)
        case .clipboard:
            ink.rect(x - 2, y - 20, 18, 23, 2.5, P.board)
            ink.rect(x, y - 17, 14, 18, 1, .white)
            ink.rect(x + 4, y - 21.5, 6, 4, 1.4, P.clip)
            for d in [0.0, 5, 10] { ink.stroke("M\(x + 3) \(y - 12 + d)h8", P.rule, 1.8, round: true) }
        case .mug:
            ink.stroke("M\(x + 4) \(y - 6)h3a3 3 0 010 6h-3", P.blue, 2)
            ink.rect(x - 5, y - 9, 10, 12, 2.4, P.blue)
            ink.stroke("M\(x - 2) \(y - 13)q-2-2.5 0-5M\(x + 2) \(y - 13)q-2-2.5 0-5", k.opacity(0.28), 1.4, round: true)
        case .mug2:
            ink.stroke("M\(x - 4) \(y - 6)h-3a3 3 0 000 6h3", P.green, 2)
            ink.rect(x - 5, y - 9, 10, 12, 2.4, P.green)
        case .magnifier:
            ink.stroke("M\(x) \(y)L\(x - 5) \(y - 8)", P.handle, 3.4, round: true)
            ink.circle(x - 9, y - 14, 8, P.lens.opacity(0.45))
            ink.strokeCircle(x - 9, y - 14, 8, P.handle, 2.8)
        case .hourglass:
            ink.rect(x - 9, y - 13, 18, 3, 1.4, P.wood)
            ink.rect(x - 9, y + 9, 18, 3, 1.4, P.wood)
            ink.fill("M\(x - 6) \(y - 10)h12l-5 9.5l5 9.5h-12l5-9.5z", P.sandGlass)
            ink.fill("M\(x - 3.2) \(y - 6)h6.4l-3.2 4.4zM\(x - 4.6) \(y + 9)h9.2l-4.6-4.8z", T.sun)
        case .page:
            let g = ink.rotated(-12, about: point)
            g.rect(x - 9, y - 20, 15, 17, 2, .white)
            g.rect(x - 9, y - 20, 15, 5, 2, P.red)
            g.text("28", x - 6.4, y - 6, 8, k)
        case .note:
            let g = ink.rotated(8, about: point)
            g.rect(x - 6, y - 18, 13, 13, 1.4, P.yellow)
            g.stroke("M\(x - 3) \(y - 13)h7M\(x - 3) \(y - 9.5)h5", k.opacity(0.5), 1.4, round: true)
        case .drink:
            ink.fill("M\(x - 5) \(y - 13)h10l-1.6 13h-6.8z", P.ice.opacity(0.9))
            ink.fill("M\(x - 4.4) \(y - 8)h8.8l-1 8h-6.8z", P.juice)
            ink.stroke("M\(x + 1) \(y - 13)l3-7", P.pink, 1.6, round: true)
            ink.circle(x - 4, y - 13, 2.6, P.yellow)
        case .lantern:
            ink.stroke("M\(x) \(y)v5", P.handle, 1.6)
            ink.circle(x, y + 13, 10, P.yellow.opacity(0.28))
            ink.rect(x - 5, y + 5, 10, 13, 3, P.lamp)
            ink.rect(x - 5.6, y + 4, 11.2, 2.6, 1.2, P.handle)
            ink.rect(x - 5.6, y + 17, 11.2, 2.6, 1.2, P.handle)
        case .plug:
            ink.stroke("M\(x + 4) \(y)q16 4 10 20t-26 15", P.clip, 2.4, round: true)
            ink.rect(x + 2, y - 5, 10, 10, 2.4, P.metal)
            ink.stroke("M\(x + 12) \(y - 2.6)h4M\(x + 12) \(y + 2.6)h4", P.rule, 1.8, round: true)
        case .paper:
            let g = ink.rotated(-6, about: point)
            g.rect(x - 7, y - 20, 16, 21, 1.6, .white)
            for d in [0.0, 4, 8, 12] { g.stroke("M\(x - 4) \(y - 16 + d)h\(d == 12 ? 6 : 10)", P.rule, 1.6, round: true) }
        case .pencil:
            ink.stroke("M\(x) \(y)l-7-8", T.sun, 3.2, round: true)
            ink.stroke("M\(x - 7) \(y - 8)l-2-2.4", k, 2, round: true)
        case .scroll:
            ink.fill("M\(x) \(y - 18)h16v44q0 4-4 4h-16", .white)
            ink.circle(x + 1, y - 18, 3, P.parchment)
            for d in stride(from: 0.0, through: 30, by: 6) { ink.stroke("M\(x + 4) \(y - 12 + d)h8", P.green, 1.8, round: true) }
        case .stamp:
            ink.rect(x - 2, y - 2, 4, 9, 1.6, P.wood)
            ink.rect(x - 6, y + 6, 12, 5, 1.6, P.red)
        case .cards:
            for (r, color) in [(-16.0, P.blue), (0, P.yellow), (16, P.green)] {
                ink.rotated(r, about: point).rect(x - 4, y - 19, 10, 15, 2, color)
            }
        case .wrench:
            ink.stroke("M\(x) \(y)l9-9", P.metal, 3.4, round: true)
            ink.fill("M\(x + 7) \(y - 13)a5 5 0 116 6l-2.4-2.4l-1.6 1.6z", P.metal)
        case .chart:
            ink.rect(x - 2, y - 20, 20, 18, 2.4, .white)
            for (dx, dy) in [(2.0, 8.0), (7, 5), (12, 7)] { ink.circle(x + dx, y - 20 + 18 - dy, 1.8, P.blue) }
        case .baton:
            ink.stroke("M\(x) \(y)l14-10", .white, 2.2, round: true)
            ink.circle(x, y, 2.4, P.handle)

        // On the glass
        case .headset:
            ink.stroke("M13 56a37 37 0 0 1 74 0", k, 4)
            ink.rect(9, 48, 9, 18, 4.5, k)
            ink.rect(82, 48, 9, 18, 4.5, k)
            ink.stroke("M84 64q-4 12-17 12", k, 2.4, round: true)
            ink.circle(67, 76, 2.6, k)
        case .thermometer:
            ink.stroke("M55 64l13 8", .white, 3.4, round: true)
            ink.stroke("M66 70.8l3 1.8", P.red, 3.4, round: true)
        case .hat:
            ink.fill("M38 26l12-26l12 26z", P.pink)
            ink.stroke("M42 18l16 0M45 11h10", P.yellow, 2.4, round: true)
            ink.circle(50, -1, 3.4, T.sun)
        case .glasses:
            ink.circle(39, 54, 7, P.lens.opacity(0.35))
            ink.circle(61, 54, 7, P.lens.opacity(0.35))
            ink.strokeCircle(39, 54, 7, k, 2)
            ink.strokeCircle(61, 54, 7, k, 2)
            ink.stroke("M46 53h8", k, 2)

        // In front
        case .book:
            ink.fill("M50 70l-22-5v20l22 5z", P.blue)
            ink.fill("M50 70l22-5v20l-22 5z", P.blueShade)
            ink.fill("M50 71l-19-4v16.4l19 4zM50 71l19-4v16.4l-19 4z", .white)
            ink.stroke("M35 72l11 2.4M35 76l11 2.4M54 74.4l11-2.4M54 78.4l11-2.4", P.rule, 1.4, round: true)
        case .scarf:
            ink.fill("M24 78q26 12 52 0v9q-26 12-52 0z", P.blue)
            ink.fill("M64 85l5 16l-8 1l-3-15z", P.blueShade)
        case .lock:
            ink.stroke("M43 76v-6a7 7 0 0114 0v6", P.metal, 3.6)
            ink.rect(38, 75, 24, 18, 4, T.sun)
            ink.circle(50, 83, 2.4, k)
            ink.stroke("M50 84v4", k, 2, round: true)
        case .laptop:
            ink.fill("M34 74h32l-3 16h-26z", P.metal)
            ink.fill("M36.5 76h27l-2.4 12h-22.2z", P.screen)
            ink.stroke("M42 80h6M42 84h12", T.coral, 1.6, round: true)
            ink.rect(28, 89, 44, 4, 2, P.rule)
        case .box:
            ink.rect(30, 72, 40, 24, 2.4, P.cardboard)
            ink.stroke("M30 78h40", P.cardboardShade, 2)
            ink.rect(42, 81, 16, 8, 1.4, .white)
            ink.text("OCT", 44, 87.6, 6, k)
        case .parcel:
            ink.rect(36, 74, 28, 20, 2.4, P.cardboard)
            ink.stroke("M50 74v20M36 82h28", P.tape, 3)
        case .stack:
            ink.rect(38, 62, 24, 15, 2.4, P.cardboardLight)
            ink.stroke("M50 62v15", P.tape, 2.6)
            ink.rect(34, 76, 32, 18, 2.4, P.cardboard)
            ink.stroke("M50 76v18M34 84h32", P.tape, 2.6)
        case .calendar:
            let g = ink.translated(70, 70)
            g.rect(0, 0, 26, 28, 3, .white)
            g.rect(0, 0, 26, 7, 3, P.red)
            for i in 0..<9 {
                g.stroke("M\(4 + Double(i % 3) * 7) \(12 + Double(i / 3) * 5.4)l1.6 1.6l3-3.2", P.green, 1.6, round: true)
            }
        case .metronome:
            let g = ink.translated(74, 66)
            g.fill("M6 0h8l6 30h-20z", P.board)
            g.fill("M5 18h10l1.6 8h-13.2z", P.wood)
            g.stroke("M10 22l5-20", k, 1.8, round: true)
        case .seal:
            ink.circle(70, 100, 6, P.red.opacity(0.85))
            ink.stroke("M67 100l2 2l4-4", .white, 1.6, round: true)
        case .blanket:
            ink.fill("M16 72q34-10 68 0l4 28q-38 8-76 0z", P.quilt)
            ink.stroke("M18 84q32-7 64 0M17 94q33-6 66 0", Color.white.opacity(0.7), 2.4)
        case .broom:
            ink.stroke("M34 64l14 30", P.board, 3, round: true)
            ink.fill("M42 92l14-6l6 14l-16 3z", P.yellow)
        }
    }
}
