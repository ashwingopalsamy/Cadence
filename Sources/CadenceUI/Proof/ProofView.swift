// The Proof section of the window (docs/SPEC.md sections 4.6 and 12), laid out as the approved prototype's four
// cards (coach/screens.js `proof`): Coverage, What your manager sees, Codes you copied, What leaves this Mac.
// Matte cards on canvas, tokens only. Discreet mode hides titles and ticket keys. No Tempo on this screen.
import AppKit
import CadenceCore
import SwiftUI
import UniformTypeIdentifiers

enum ProofMetrics {
    /// Below this width the cards stack in one column, as the prototype's `@container app (max-width: 800px)`.
    static let twoColumnsFrom: CGFloat = 800
    static let gap = CadenceSpace.s12
    static let cardPadding = CadenceSpace.s16
    /// The section head: label and control on the first line, the title on the second (section 6.4).
    static let headLine = CadenceSize.controlSecondary
    static let focusRing = CadenceSpace.s2
    static let pressScale: CGFloat = 0.97
    static let disabled = 0.45
    /// The seg's selected fill sits on `ink` at this strength, as the prototype's `.seg`.
    static let segTrack = 0.08
    /// A status block's ground: its colour at this strength (`.status.ok`, `.status.bad`).
    static let statusTint = 0.13
    /// The on-world button's ground: its ink at this strength (`.onworld`), a step stronger under the pointer.
    static let onWorldTint = 0.14
    static let onWorldHover = 0.2
    /// A quiet control under the pointer: `ink` mixed into its ground at this strength (`.choice:hover`).
    static let hoverTint = 0.12
    /// A family dot in a found row.
    static let dot = CadenceSpace.s8
    /// The time column of a found row, wide enough for "00:00" in the figure face.
    static let timeColumn = CadenceSpace.s40
}

/// Type roles for this screen, all from the section 6.3 scale.
enum ProofType {
    static let kick = CadenceType.label
    static let title = CadenceType.section
    static let say = CadenceType.sentence
    static let number = CadenceType.numeral
    static let unit = CadenceType.numeralUnit
    static let comparison = CadenceType.comparison
    static let row = CadenceType.body
    static let hint = CadenceType.comparison
    static let time = CadenceType.figure
    static let ticket = CadenceType.figure
    /// Status blocks, the seg and quiet controls: 13/20 semibold.
    static let control = TypeToken(name: "proof control", face: .sfPro, size: 13, lineHeight: 20, weight: 600, tracking: 0, sample: "Check a file")
    /// The primary button: 14/20 bold.
    static let primary = TypeToken(name: "proof primary", face: .sfPro, size: 14, lineHeight: 20, weight: 700, tracking: 0, sample: "Export and check")
    /// The on-world button: 13/20 bold.
    static let onWorld = TypeToken(name: "proof on world", face: .sfPro, size: 13, lineHeight: 20, weight: 700, tracking: 0, sample: "See approved sources")
    /// "What leaves this Mac" lines: 13/20 medium, as the prototype's `.legend`.
    static let legend = TypeToken(name: "proof legend", face: .sfPro, size: 13, lineHeight: 20, weight: 500, tracking: 0, sample: "Anyone can check the file")
    /// An origin word in a row: 11/16 semibold, untracked.
    static let origin = TypeToken(name: "proof origin", face: .sfPro, size: 11, lineHeight: 16, weight: 600, tracking: 0, sample: "collected")
}

/// The save and open panels. The sandbox grants the app exactly the file chosen here (section 8.3), so the
/// destination is never a fixed path.
public enum ProofPanels {
    @MainActor public static func save(suggesting name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor public static func open() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

public struct ProofView: View {
    let model: ProofModel
    let discreet: Bool
    let openSources: () -> Void
    let chooseDestination: @MainActor (String) -> URL?
    let chooseFile: @MainActor () -> URL?

    @Environment(\.locale) private var locale
    @State private var width: CGFloat = 0

    public init(
        model: ProofModel, discreet: Bool = false, openSources: @escaping () -> Void = {},
        chooseDestination: @escaping @MainActor (String) -> URL? = ProofPanels.save(suggesting:),
        chooseFile: @escaping @MainActor () -> URL? = ProofPanels.open
    ) {
        self.model = model
        self.discreet = discreet
        self.openSources = openSources
        self.chooseDestination = chooseDestination
        self.chooseFile = chooseFile
    }

    private var failed: Bool { model.outcome.map { !$0.passed } ?? false }

    public var body: some View {
        VStack(alignment: .leading, spacing: ProofMetrics.gap) {
            head
            if case .failed(let failure) = model.load {
                ProofCard {
                    Kicker(ProofCopy.coverage)
                    Text(failure.summary).cadenceType(ProofType.say).foregroundStyle(CadenceColor.ink.color)
                    Text(failure.detail).cadenceType(ProofType.comparison).foregroundStyle(CadenceColor.ink3.color)
                }
            } else {
                cards
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task { if model.load == .loading { await model.reload() } }
        .onChange(of: model.outcome) { _, outcome in
            guard let outcome else { return }
            let text = "\(ProofCopy.outcomeHead(outcome)) \(ProofCopy.outcomeBody(outcome))"
            AccessibilityNotification.Announcement(text).post()
        }
    }

    // MARK: Head

    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ProofMetrics.gap) {
                Kicker(ProofCopy.kicker)
                Spacer(minLength: 0)
                Button(model.working == .checked ? ProofCopy.checking : ProofCopy.checkFile) { checkFile() }
                    .buttonStyle(ProofQuietStyle())
                    .disabled(model.working != nil)
            }
            .frame(height: ProofMetrics.headLine)
            Text(failed ? ProofCopy.doNotShare : ProofCopy.title(model.preset, range: model.snapshot?.range, locale: locale))
                .cadenceType(ProofType.title)
                .foregroundStyle(CadenceColor.ink.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: ProofMetrics.headLine)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Cards

    @ViewBuilder private var cards: some View {
        let snapshot = model.snapshot
        if width == 0 || width >= ProofMetrics.twoColumnsFrom {
            Grid(horizontalSpacing: ProofMetrics.gap, verticalSpacing: ProofMetrics.gap) {
                GridRow {
                    coverage(snapshot)
                    manager(snapshot)
                }
                GridRow {
                    codes(snapshot)
                    leaves(snapshot)
                }
            }
            // Cards in a row share its height (`.wide`, align-items: stretch) without growing past their content.
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: ProofMetrics.gap) {
                coverage(snapshot)
                manager(snapshot)
                codes(snapshot)
                leaves(snapshot)
            }
        }
    }

    private func coverage(_ s: ProofSnapshot?) -> some View {
        ProofCard {
            Kicker(ProofCopy.coverage)
            Say(ProofCopy.covers)
            ProofNumeral(value: s?.sealedWorkdays.map(String.init) ?? "-", unit: ProofCopy.sealedUnit)
            Comparison(s.map { ProofCopy.coverageLine($0, locale: locale) } ?? "-")
            PresetBar(selected: model.preset) { preset in Task { await model.select(preset) } }
                .padding(.vertical, CadenceSpace.s12)
            if model.preset == .custom, let range = s?.range ?? model.custom {
                CustomRange(range: range, today: s?.today) { range in Task { await model.setCustom(range) } }
                    .padding(.bottom, CadenceSpace.s8)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ProofCopy.inclusion(s?.inclusion ?? ProofInclusion(titled: 0, digest: 0, excluded: 0))) { row in
                    InclusionRow(label: row.label, value: s == nil ? "-" : row.value)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(ProofCopy.included)
        }
    }

    private func manager(_ s: ProofSnapshot?) -> some View {
        ProofCard {
            Kicker(ProofCopy.managerSees)
            Say(ProofCopy.planDone)
            ProofNumeral(value: ProofCopy.percent(s?.planDone, of: s?.planned).map(String.init) ?? "-", unit: "%")
            Comparison(s.map(ProofCopy.sealedLine) ?? "-")
            VStack(spacing: 0) {
                let preview = s?.preview ?? []
                ForEach(Array(preview.enumerated()), id: \.element.id) { index, item in
                    PreviewRow(item: item, index: index, discreet: discreet, last: index == preview.count - 1)
                }
            }
            .padding(.top, CadenceSpace.s8)
            Spacer(minLength: CadenceSpace.s12)
            HStack {
                Button(model.working == .exported ? ProofCopy.exporting : ProofCopy.export) { exportAndCheck() }
                    .buttonStyle(ProofPrimaryStyle())
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.working != nil || s == nil)
                Spacer(minLength: 0)
            }
            if let outcome = model.outcome {
                OutcomeBlock(outcome: outcome, exportAgain: exportAndCheck)
                    .transition(.opacity)
            }
            Text(ProofCopy.limits)
                .cadenceType(ProofType.hint)
                .foregroundStyle(CadenceColor.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, CadenceSpace.s8)
        }
        .cadenceAnimation(CadenceMotion.entry.animation, value: model.outcome)
    }

    private func codes(_ s: ProofSnapshot?) -> some View {
        ProofCard {
            Kicker(ProofCopy.codesKicker)
            Say(s.map(ProofCopy.codesLine) ?? "-")
            VStack(spacing: 0) {
                let days = s?.codeDays ?? []
                ForEach(days) { day in
                    CodeRow(
                        day: ProofCopy.day(day.date, locale: locale), day.copiedAt.map { String(localized: "Copied \($0)") } ?? ProofCopy.notCopied,
                        code: day.code, last: day.id == days.last?.id)
                }
            }
            .padding(.top, CadenceSpace.s8)
        }
    }

    private func leaves(_ s: ProofSnapshot?) -> some View {
        ProofCard {
            Kicker(ProofCopy.leavesKicker)
            Say(ProofCopy.noNetwork)
            VStack(alignment: .leading, spacing: CadenceSpace.s8) {
                ForEach([ProofCopy.sourcesLine(s?.sources ?? []), ProofCopy.sentNowhere, ProofCopy.openVerifier], id: \.self) { line in
                    Text(line)
                        .cadenceType(ProofType.legend)
                        .foregroundStyle(CadenceColor.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, CadenceSpace.s8)
            Button(ProofCopy.seeSources, action: openSources)
                .buttonStyle(ProofOnWorldStyle())
                .padding(.top, CadenceSpace.s8)
        }
    }

    // MARK: Actions

    private func exportAndCheck() {
        guard let name = model.suggestedFileName, let url = chooseDestination(name) else { return }
        Task { await model.export(to: url) }
    }

    private func checkFile() {
        guard let url = chooseFile() else { return }
        Task { await model.check(url) }
    }
}

// MARK: - Parts

/// A matte card: `card` on `canvas`, 24-point corners, 16-point padding, no shadow (section 6.1).
struct ProofCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(ProofMetrics.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cadenceCard()
            .accessibilityElement(children: .contain)
    }
}

/// The card's label slot: 16 high.
struct Kicker: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .cadenceType(ProofType.kick)
            .foregroundStyle(CadenceColor.ink3.color)
            .lineLimit(1)
            .frame(minHeight: CadenceSize.labelSlot, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The sentence slot, 20 high per line, 4 below the label.
private struct Say: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .cadenceType(ProofType.say)
            .foregroundStyle(CadenceColor.ink.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: CadenceSize.sentenceSlot, alignment: .leading)
            .padding(.top, CadenceSpace.s4)
    }
}

/// The number slot: a heavy rounded numeral with a small unit, 48 high.
private struct ProofNumeral: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: CadenceSpace.s4) {
            Text(value).cadenceType(ProofType.number)
            Text(unit).cadenceType(ProofType.unit)
        }
        .foregroundStyle(CadenceColor.ink.color)
        .lineLimit(1)
        .frame(height: CadenceSize.numberSlot, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value == "-" ? String(localized: "Not known yet") : "\(value) \(unit == "%" ? String(localized: "percent") : unit)")
    }
}

/// The comparison slot, 16 high.
private struct Comparison: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .cadenceType(ProofType.comparison)
            .foregroundStyle(CadenceColor.ink3.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: CadenceSize.comparisonSlot, alignment: .leading)
    }
}

/// The range presets, as the prototype's `.seg`: a 28-point track with the choice lifted onto `card`.
private struct PresetBar: View {
    let selected: ProofPreset
    let choose: (ProofPreset) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ProofPreset.allCases) { preset in
                Button(preset.title) { choose(preset) }
                    .buttonStyle(SegmentStyle(on: preset == selected))
                    .accessibilityAddTraits(preset == selected ? .isSelected : [])
            }
        }
        .padding(CadenceSpace.s2)
        .frame(height: CadenceSize.controlToolbar)
        .background(Capsule().fill(CadenceColor.ink.color.opacity(ProofMetrics.segTrack)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ProofCopy.range)
    }
}

private struct SegmentStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        Segment(configuration: configuration, on: on)
    }

    private struct Segment: View {
        let configuration: ButtonStyleConfiguration
        let on: Bool
        @State private var hover = false
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .cadenceType(ProofType.control)
                .foregroundStyle(on || hover ? CadenceColor.ink.color : CadenceColor.ink2.color)
                .lineLimit(1)
                .padding(.horizontal, CadenceSpace.s12)
                .frame(height: CadenceSize.chip)
                .background(Capsule().fill(on ? CadenceColor.card.color : Color.clear))
                .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: ProofMetrics.focusRing))
                .contentShape(Capsule())
                .onHover { hover = $0 }
        }
    }
}

/// Custom: two dates, read in the profile zone. The model keeps them in order and never past today.
private struct CustomRange: View {
    let range: ProofRange
    let today: LocalDate?
    let change: (ProofRange) -> Void

    var body: some View {
        HStack(spacing: CadenceSpace.s12) {
            picker(ProofCopy.from, range.from) { change(ProofRange(from: $0, to: range.to)) }
            picker(ProofCopy.to, range.to) { change(ProofRange(from: range.from, to: $0)) }
        }
    }

    private func picker(_ label: String, _ day: LocalDate, _ set: @escaping (LocalDate) -> Void) -> some View {
        HStack(spacing: CadenceSpace.s4) {
            Text(label)
            DayPopoverButton(
                label: label,
                date: Binding(get: { Self.instant(day) }, set: { set(Self.day($0)) }),
                through: Self.instant(today ?? day), calendar: Self.calendar)
        }
        .cadenceType(ProofType.control)
        .foregroundStyle(CadenceColor.ink2.color)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func instant(_ day: LocalDate) -> Date {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date()
    }

    static func day(_ instant: Date) -> LocalDate {
        let c = calendar.dateComponents([.year, .month, .day], from: instant)
        return LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1) ?? LocalDate(year: 1970, month: 1, day: 1)!
    }
}

/// One line of "What is included": what leaves and how much. A statement, not a switch.
private struct InclusionRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: CadenceSpace.s12) {
            Text(label)
                .cadenceType(ProofType.row)
                .foregroundStyle(CadenceColor.ink.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(value)
                .cadenceType(ProofType.control)
                .foregroundStyle(CadenceColor.ink2.color)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minHeight: CadenceSize.settingsRow)
        .overlay(alignment: .bottom) { Rule() }
        .accessibilityElement(children: .combine)
    }
}

/// A hairline in `line`.
private struct Rule: View {
    var body: some View {
        Rectangle().fill(CadenceColor.line.color).frame(height: CadenceStroke.hair)
    }
}

/// One item as the file lists it: time, family dot, title or what is kept back, ticket, origin. 36 high, one line.
private struct PreviewRow: View {
    let item: ProofPreviewItem
    let index: Int
    let discreet: Bool
    /// The last row of a list has no rule under it (`.found:last-child`).
    let last: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColour

    private var kindName: String { item.kind.map(CaptureAdapter.kindName) ?? String(localized: "Item") }

    private var title: String {
        guard let title = item.title else { return String(localized: "\(kindName), title hidden") }
        return discreet ? String(localized: "Item \(index + 1)") : title
    }

    private var ticket: String? { discreet ? nil : item.ticket }

    var body: some View {
        HStack(spacing: CadenceSpace.s8) {
            Text(item.time ?? "-")
                .cadenceType(ProofType.time)
                .foregroundStyle(CadenceColor.ink3.color)
                .frame(width: ProofMetrics.timeColumn, alignment: .leading)
            FamilyDot(family: item.family ?? .presence, size: ProofMetrics.dot)
            // Differentiate Without Colour: the kind of work says its name too (section 6.7).
            if withoutColour, let family = item.family {
                Text(EntryWords.family(family))
                    .cadenceType(CadenceType.label)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(title)
                .cadenceType(ProofType.row)
                .foregroundStyle(item.redacted ? CadenceColor.ink2.color : CadenceColor.ink.color)
                .lineLimit(1)
                .truncationMode(.tail)
            if let ticket { Ticket(text: ticket) }
            Spacer(minLength: 0)
            Text(item.origin)
                .cadenceType(ProofType.origin)
                .foregroundStyle(CadenceColor.ink3.color)
                .fixedSize()
        }
        .frame(minHeight: CadenceSize.foundRow)
        .overlay(alignment: .bottom) { if !last { Rule() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.time, kindName, title, ticket, String(localized: "origin \(item.origin)")].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A ticket key, code or other figure on `track`: 20 high, 8-point corners.
private struct Ticket: View {
    let text: String

    var body: some View {
        Text(text)
            .cadenceType(ProofType.ticket)
            .foregroundStyle(CadenceColor.ink2.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, CadenceSpace.s6)
            .frame(height: CadenceSize.ticket)
            .background(RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous).fill(CadenceColor.track.color))
    }
}

/// A sealed day and its code.
private struct CodeRow: View {
    let day: String
    let note: String
    let code: String?
    let last: Bool

    init(day: String, _ note: String, code: String?, last: Bool) {
        self.day = day
        self.note = note
        self.code = code
        self.last = last
    }

    var body: some View {
        HStack(spacing: CadenceSpace.s8) {
            Text(day)
                .cadenceType(ProofType.row)
                .foregroundStyle(CadenceColor.ink.color)
                .lineLimit(1)
                .fixedSize()
            Text(note)
                .cadenceType(ProofType.hint)
                .foregroundStyle(CadenceColor.ink3.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let code { Ticket(text: code) }
        }
        .frame(minHeight: CadenceSize.foundRow)
        .overlay(alignment: .bottom) { if !last { Rule() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([day, note, code.map { String(localized: "code \($0)") }].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The result of Export and check or Check a file: `good` on a tint of itself when it passed, `warn` when it did not.
private struct OutcomeBlock: View {
    let outcome: ProofOutcome
    let exportAgain: () -> Void

    private var tone: ColorToken { outcome.passed ? CadenceColor.good : CadenceColor.warn }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CadenceSpace.s4) {
                if outcome.passed { Image(systemName: "checkmark").cadenceIcon(size: CadenceIcon.small) }
                Text(ProofCopy.outcomeHead(outcome)).fontWeight(.bold)
            }
            Text(ProofCopy.outcomeBody(outcome))
                .fixedSize(horizontal: false, vertical: true)
            if let digest = outcome.digestLine, outcome.passed {
                Text(digest)
                    .cadenceType(ProofType.time)
                    .padding(.top, CadenceSpace.s4)
                    .help(outcome.exportDigest ?? "")
                    .accessibilityLabel("Export digest \(outcome.exportDigest ?? "")")
            }
            if !outcome.passed, outcome.action == .exported {
                Button(ProofCopy.exportAgain, action: exportAgain)
                    .buttonStyle(ProofQuietStyle(ground: CadenceColor.card))
                    .padding(.top, CadenceSpace.s8)
            }
        }
        .cadenceType(ProofType.control)
        .foregroundStyle(tone.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, CadenceSpace.s8)
        .padding(.horizontal, CadenceSpace.s12)
        .background(
            RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous)
                .fill(tone.color.opacity(ProofMetrics.statusTint)))
        .padding(.top, CadenceSpace.s8)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Buttons

/// Primary: `ink` capsule with `canvas` text, 40 high (section 6.1, Controls).
struct ProofPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsuled(
            configuration: configuration, type: ProofType.primary, height: CadenceSize.controlPrimary,
            padding: CadenceSpace.s16, text: CadenceColor.canvas, ground: CadenceColor.ink.color, hover: CadenceColor.ink.color)
    }
}

/// Quiet: `track` capsule with `ink` text, 32 high. Inside a status block it sits on `card`.
struct ProofQuietStyle: ButtonStyle {
    var ground = CadenceColor.track

    func makeBody(configuration: Configuration) -> some View {
        Capsuled(
            configuration: configuration, type: ProofType.control, height: CadenceSize.controlSecondary,
            padding: CadenceSpace.s12, text: CadenceColor.ink, ground: ground.color,
            hover: CadenceColor.ink.color.mix(with: ground.color, by: 1 - ProofMetrics.hoverTint))
    }
}

/// On a card: the button takes `ink` at a low strength, as the prototype's `.onworld.dark`.
struct ProofOnWorldStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsuled(
            configuration: configuration, type: ProofType.onWorld, height: CadenceSize.controlSecondary,
            padding: CadenceSpace.s12, text: CadenceColor.ink, ground: CadenceColor.ink.color.opacity(ProofMetrics.onWorldTint),
            hover: CadenceColor.ink.color.opacity(ProofMetrics.onWorldHover))
    }
}

/// A capsule in rest, hover, pressed, focus and disabled. Press settles a touch smaller unless Reduce Motion is on.
private struct Capsuled: View {
    let configuration: ButtonStyleConfiguration
    let type: TypeToken
    let height: CGFloat
    let padding: CGFloat
    let text: ColorToken
    let ground: Color
    let hover: Color

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .cadenceType(type)
            .foregroundStyle(text.color)
            .lineLimit(1)
            .padding(.horizontal, padding)
            .frame(height: height)
            .background(Capsule().fill(hovering && enabled ? hover : ground))
            .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: ProofMetrics.focusRing))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : ProofMetrics.disabled)
            .scaleEffect(configuration.isPressed && !reduceMotion ? ProofMetrics.pressScale : 1)
            .cadenceAnimation(CadenceMotion.press.animation, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
