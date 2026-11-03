// The recap pager (docs/SPEC.md sections 5.5 and 5.7): full bleed on the frame's deep colour, a progress bar, the
// caption, Tempo, the headline and paragraph, and the tiles landing one after another. ← and → page, Esc closes.
// Reduce Motion shows every tile at once.
import AppKit
import CadenceCore
import SwiftUI

public struct StoryView: View {
    let recap: Recap
    let discreet: Bool
    let onClose: () -> Void

    @State private var index: Int
    @State private var copied = false
    @State private var width: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `discreet` hides Tempo and turns delivered titles into "Item 1" (section 6.7).
    public init(recap: Recap, startAt: Int = 0, discreet: Bool = false, onClose: @escaping () -> Void) {
        self.recap = recap
        self.discreet = discreet
        self.onClose = onClose
        _index = State(initialValue: min(max(0, startAt), max(0, recap.frames.count - 1)))
    }

    public var body: some View {
        if recap.frames.indices.contains(index) {
            page(recap.frames[index])
        }
    }

    private var stacked: Bool { width > 0 && width < RecapTokens.frameStack }
    private var isLast: Bool { index >= recap.frames.count - 1 }

    private func page(_ frame: RecapFrame) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            progress
                .padding(.bottom, CadenceSpace.s16)
            HStack(alignment: .center) {
                Text(frame.caption)
                    .cadenceType(RecapTokens.caption)
                    .lineLimit(1)
                Spacer(minLength: CadenceSpace.s12)
                StoryButton(symbol: "xmark", label: String(localized: "Close recap"), action: onClose)
            }
            words(frame)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            HStack(spacing: CadenceSpace.s8) {
                StoryButton(title: copied ? String(localized: "Copied") : String(localized: "Copy as text"), action: copy)
                Spacer(minLength: CadenceSpace.s12)
                StoryButton(title: String(localized: "Back"), action: back)
                    .opacity(index == 0 ? 0 : 1)
                    .disabled(index == 0)
                    .accessibilityHidden(index == 0)
                StoryButton(title: isLast ? String(localized: "Done") : String(localized: "Next"), action: next)
            }
        }
        .padding(.horizontal, stacked ? CadenceSpace.s16 : CadenceSpace.s32)
        .padding(.vertical, CadenceSpace.s16)
        .foregroundStyle(frame.deep.ink.color)
        .background(frame.deep.bg.color)
        .environment(\.colorScheme, frame.deep.isNight ? .dark : .light)
        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous))
        .cadenceAnimation(CadenceMotion.world.animation, value: index)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The key target is a sibling of the buttons, so only a button that itself has focus draws a ring.
        .background {
            Color.clear
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) { back(); return .handled }
                .onKeyPress(.rightArrow) { next(); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
                .accessibilityHidden(true)
        }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(recap.name), frame \(index + 1) of \(recap.frames.count)")
    }

    private var progress: some View {
        HStack(spacing: CadenceSpace.s4) {
            ForEach(recap.frames.indices, id: \.self) { i in
                Capsule()
                    .opacity(i <= index ? 1 : RecapTokens.barRest)
                    .frame(height: RecapTokens.barHeight)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func words(_ frame: RecapFrame) -> some View {
        let text = VStack(alignment: .leading, spacing: 0) {
            if !discreet {
                TempoView(frame.tempo, size: RecapTokens.tempo)
                    .padding(.bottom, CadenceSpace.s4)
            }
            Text(frame.headline)
                .cadenceType(stacked ? RecapTokens.headlineCompact : RecapTokens.headline)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, CadenceSpace.s8)
                .padding(.bottom, CadenceSpace.s12)
                .accessibilityAddTraits(.isHeader)
            let paragraph = frame.shownParagraph(discreet: discreet)
            if !paragraph.isEmpty {
                Text(paragraph)
                    .cadenceType(RecapTokens.paragraph)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if stacked {
            VStack(alignment: .leading, spacing: CadenceSpace.s16) {
                text
                tiles(frame)
            }
        } else {
            // Words and tiles share the width 1.25 to 1, as the design's frame does.
            let inner = max(0, width - 2 * CadenceSpace.s32 - CadenceSpace.s32)
            let words = inner * RecapTokens.wordsShare / (RecapTokens.wordsShare + 1)
            HStack(alignment: .center, spacing: CadenceSpace.s32) {
                text
                    .frame(width: words, alignment: .leading)
                tiles(frame)
                    .frame(maxWidth: max(0, inner - words), alignment: .trailing)
            }
        }
    }

    @ViewBuilder private func tiles(_ frame: RecapFrame) -> some View {
        if frame.drawsTiles {
            TileGrid(frame: frame)
                .id(index)
        }
    }

    // MARK: actions

    private func next() {
        guard !isLast else { return onClose() }
        index += 1
        copied = false
    }

    private func back() {
        guard index > 0 else { return }
        index -= 1
        copied = false
    }

    private func copy() {
        RecapCopy.write(recap, discreet: discreet, to: .general)
        copied = true
    }
}

/// Copy as text: plain text and Markdown on the pasteboard together, so each app takes the one it reads.
public enum RecapCopy {
    public static let markdown = NSPasteboard.PasteboardType("net.daringfireball.markdown")

    public static func write(_ recap: Recap, discreet: Bool, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(recap.plainText(discreet: discreet), forType: .string)
        pasteboard.setString(recap.markdown(discreet: discreet), forType: markdown)
    }
}

/// The tiles of one frame, with a legend that prints every count, so the picture has its table beside it.
struct TileGrid: View {
    let frame: RecapFrame
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var styles: [RecapTiles.Style] {
        frame.tiles.flatMap { Array(repeating: $0.style, count: max(0, $0.count)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s12) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: CadenceSpace.s8), count: frame.columns),
                spacing: CadenceSpace.s8
            ) {
                ForEach(Array(styles.enumerated()), id: \.offset) { i, style in
                    Tile(style: style)
                        .aspectRatio(1, contentMode: .fit)
                        .scaleEffect(shown ? 1 : RecapTokens.tileFrom)
                        .opacity(shown ? 1 : 0)
                        .animation(
                            CadenceMotion.resolved(
                                CadenceMotion.recapTile.animation.delay(Double(i) * RecapTokens.tileStagger), reduceMotion: reduceMotion),
                            value: shown)
                }
            }
            .frame(width: frame.gridWidth)
            .accessibilityHidden(true)
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(frame.tileSummary)
        .onAppear { shown = true }
    }

    private var legend: some View {
        HStack(spacing: CadenceSpace.s12) {
            ForEach(Array(frame.tiles.filter { $0.count > 0 }.enumerated()), id: \.offset) { _, run in
                HStack(spacing: CadenceSpace.s6) {
                    Tile(style: run.style)
                        .frame(width: CadenceIcon.small, height: CadenceIcon.small)
                    Text("\(run.count) \(run.label)")
                        .cadenceType(CadenceType.comparison)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// One tile: solid, outlined or faint, in the frame's ink, so the three differ by form and not by colour alone.
struct Tile: View {
    let style: RecapTiles.Style

    var body: some View {
        switch style {
        case .solid: TileShape().fill(.foreground)
        case .outlined: TileShape().strokeBorder(.foreground, lineWidth: RecapTokens.tileStroke)
        // The faint fill alone is below 3:1 on every deep ground, so a full-ink hairline carries the mark.
        case .faint:
            TileShape().fill(.foreground).opacity(RecapTokens.faintOpacity)
                .overlay(TileShape().strokeBorder(.foreground, lineWidth: RecapTokens.faintStroke))
        }
    }
}

/// A square with corners at a share of its side, so every size keeps the same shape.
struct TileShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let radius = min(rect.width, rect.height) * RecapTokens.tileCorner - inset
        return RoundedRectangle(cornerRadius: max(0, radius), style: .continuous).path(in: box)
    }

    func inset(by amount: CGFloat) -> TileShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// The story's quiet buttons: the frame's ink, a wash on hover and press, the system focus ring.
struct StoryButton: View {
    var title: String?
    var symbol: String?
    var label: String?
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    init(symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: CadenceIcon.large, weight: CadenceIcon.weight(CadenceIcon.panelWeight, contrast)))
                        .frame(width: CadenceSize.controlSecondary)
                } else {
                    Text(title ?? "").cadenceType(RecapTokens.action)
                }
            }
        }
        .buttonStyle(WashStyle())
        .accessibilityLabel(label ?? title ?? "")
    }
}

/// Quiet on a coloured ground: the ink at a low opacity behind the label on hover or press.
struct WashStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WashBody(configuration: configuration)
    }

    private struct WashBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .padding(.horizontal, CadenceSpace.s8)
                .frame(height: CadenceSize.controlSecondary)
                .background(
                    RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
                        .fill(.foreground)
                        .opacity(enabled && (hovering || configuration.isPressed) ? RecapTokens.wash : 0)
                )
                .contentShape(RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous))
                .onHover { hovering = $0 }
                .cadenceAnimation(CadenceMotion.press.animation, value: hovering || configuration.isPressed)
        }
    }
}
