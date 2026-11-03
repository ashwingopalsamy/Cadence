// The chips and buttons the log fields and rows share (docs/SPEC.md sections 4.3, 4.6 and 6.7): the kind a typed line
// will save as, with a menu to change it; the link it carries; and the glyph that opens an entry's first link in the
// system browser. A control draws its own focus ring only while it has keyboard focus, and the system ring is off.
import AppKit
import CadenceCore
import SwiftUI

/// A small capsule inside a field: the label type on a tint of `ink`.
private struct FieldChipLook: ViewModifier {
    var hover = false

    func body(content: Content) -> some View {
        content
            .cadenceType(CadenceType.label)
            .foregroundStyle(hover ? CadenceColor.ink.color : CadenceColor.ink2.color)
            .lineLimit(1)
            .padding(.horizontal, CadenceSpace.s8)
            .frame(height: CadenceSize.chip)
            .background(Capsule().fill(CadenceColor.ink.color.opacity(TodayGeometry.fieldButtonTint)))
    }
}

/// The chip's button style: the look, a lift under the pointer, and the focus ring only when it has focus.
struct FieldChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FieldChipBody(configuration: configuration)
    }
}

private struct FieldChipBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .modifier(FieldChipLook(hover: hover || configuration.isPressed))
            .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: ListMetrics.focusRing))
            .contentShape(Capsule())
            .onHover { hover = $0 }
    }
}

/// The kind a typed line will save as, in its work colour with its name. A click opens the kinds a person logs, under
/// their work kind; a pick stays until the field is cleared. "Note" is what a line that names no kind saves as.
struct LogKindChip: View {
    let line: LogLine
    let pick: (EntryKind?) -> Void

    var body: some View {
        Menu {
            if line.picked {
                Button(LogLine.automatic) { pick(nil) }
                Divider()
            }
            ForEach(TitleEdit.kindsByFamily, id: \.family) { group in
                Section(EntryWords.family(group.family)) {
                    ForEach(group.kinds, id: \.self) { option in
                        Toggle(isOn: Binding(get: { option == line.kind }, set: { if $0 { pick(option) } })) {
                            Label {
                                Text(CaptureAdapter.kindName(option))
                            } icon: {
                                Image(nsImage: FamilyDotImage.image(group.family))
                            }
                        }
                        .accessibilityLabel("\(CaptureAdapter.kindName(option)), \(EntryWords.family(group.family))")
                    }
                }
            }
        } label: {
            HStack(spacing: CadenceSpace.s6) {
                FamilyDot(family: line.family)
                Text(line.kindName)
            }
        }
        .menuStyle(.button)
        .buttonStyle(FieldChipStyle())
        .focusEffectDisabled()
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(line.kindVoice)
    }
}

/// The link a typed line carries, named: "PR #88". Information only; the link leaves the title and travels with the
/// entry.
struct LogLinkChip: View {
    let line: LogLine

    var body: some View {
        if let name = line.linkChip {
            HStack(spacing: CadenceSpace.s4) {
                Image(systemName: "link").cadenceIcon(size: CadenceIcon.small - CadenceSpace.s2)
                Text(name)
            }
            .modifier(FieldChipLook())
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.linkVoice ?? name)
        }
    }
}

/// A small link glyph that opens a link in the system browser: "Open PR #88". Cadence has no network code; the address
/// goes to the default browser.
struct LinkGlyphButton: View {
    let target: LinkTarget
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = target.url {
            Button {
                openURL(url)
            } label: {
                Image(systemName: "link")
                    .cadenceIcon(size: CadenceIcon.small)
                    .foregroundStyle(CadenceColor.ink2.color)
                    .frame(width: CadenceSize.chip, height: CadenceSize.chip)
            }
            .buttonStyle(RowButtonStyle(capsule: true))
            .focusEffectDisabled()
            .help(target.help ?? "")
            .accessibilityLabel(target.openVoice)
        }
    }
}
