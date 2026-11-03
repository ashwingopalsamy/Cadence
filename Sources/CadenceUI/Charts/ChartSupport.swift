// What every chart shares (docs/SPEC.md sections 5.4, 6.4, 6.6 and 6.7): a VoiceOver sentence, a table twin with the
// same figures, its sizes and type roles built from the tokens, the hatching of partial weeks, and the words for dates.
// Unknown prints as "-" and is never drawn as zero.
import AppKit
import CadenceCore
import SwiftUI

/// What a chart carries besides its picture: one sentence for VoiceOver and the same figures as a table.
public protocol ChartFigures: Sendable, Equatable {
    /// The chart read as a sentence (section 6.7).
    var summary: String { get }
    /// The table twin. Every figure the picture prints is in it.
    var table: ChartTable { get }
}

/// A chart's table twin: column heads and one row of cells per mark.
public struct ChartTable: Sendable, Equatable {
    public var columns: [String]
    public var rows: [[String]]

    public init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }
}

/// The colour a chart draws in: the brand for charts about you, or a work colour for a kind of work (section 6.2).
public enum ChartHue: Sendable, Equatable {
    case brand
    case family(Family)

    var token: ColorToken {
        switch self {
        case .brand: CadenceColor.brand
        case .family(let family): CadenceColor.family(family)
        }
    }

    /// Text on a full fill of this hue.
    var onFill: ColorToken {
        switch self {
        case .brand: CadenceColor.onBrand
        case .family: ChartColor.onAccent
        }
    }
}

enum ChartColor {
    /// Text on a work colour or a mixed brand fill. The work colours stay light in both themes, so this is the light
    /// theme's ink in both, as the prototype's `--on-accent`.
    static let onAccent = ColorToken(name: "on-accent", role: "Text on a work colour", light: CadenceColor.ink.light, dark: CadenceColor.ink.light)
}

/// The charts' own type roles, sized from the scale of section 6.3.
enum ChartType {
    /// A value printed over a bar.
    static let value = TypeToken(name: "chart value", face: .sfRounded, size: 13, lineHeight: 20, weight: 800, tracking: 0, sample: "86%")
    /// A count printed inside a wide fill: the split bar.
    static let inside = TypeToken(name: "chart inside", face: .sfRounded, size: 18, lineHeight: 24, weight: 800, tracking: 0, sample: "12")
    /// A count printed inside a layer: strata.
    static let layer = TypeToken(name: "chart layer", face: .sfRounded, size: 14, lineHeight: 20, weight: 800, tracking: 0, sample: "5")
    /// The word beside a count inside a fill.
    static let word = TypeToken(name: "chart word", face: .sfPro, size: 12, lineHeight: 16, weight: 600, tracking: 0, sample: "Self-started")
    /// A calendar day's number.
    static let day = TypeToken(name: "chart day", face: .sfRounded, size: 11, lineHeight: 16, weight: 700, tracking: 0, sample: "29")
    /// Axis and bar labels.
    static let axis = TypeToken(name: "chart axis", face: .sfPro, size: 11, lineHeight: 16, weight: 600, tracking: 0, sample: "W43")
    /// The note under a chart: "Hatched weeks are partial."
    static let hint = CadenceType.comparison
    /// A count tile's number.
    static let tile = TypeToken(name: "chart tile", face: .sfRounded, size: 28, lineHeight: 32, weight: 900, tracking: -0.025, sample: "19")
    /// Table heads.
    static let tableHead = CadenceType.label
    /// Table cells: 13/20 with tabular figures.
    static let tableCell = TypeToken(name: "table cell", face: .sfPro, size: 13, lineHeight: 20, weight: 400, tracking: 0, sample: "14 of 18")
    /// The band's labels on the hero.
    static let band = TypeToken(name: "band label", face: .sfPro, size: 12, lineHeight: 16, weight: 600, tracking: 0, sample: "Usual day: 5 to 9.")
    /// "Today, 8" beside the band's mark.
    static let bandToday = TypeToken(name: "band today", face: .sfRounded, size: 13, lineHeight: 16, weight: 800, tracking: 0, sample: "Today, 8")
}

/// Sizes from the approved prototype's chart rules (coach.css), each a token or a sum of tokens.
enum ChartMetrics {
    /// The tallest bar of the week bars.
    static let plot: CGFloat = CadenceSpace.s48 + CadenceSpace.s16
    /// Every bar keeps at least this much, so a small known value still shows.
    static let minBar = CadenceSpace.s4
    static let barGap = CadenceSpace.s8
    static let barRadius = CadenceRadius.small
    /// The hatching of partial weeks: a light fill with stronger stripes.
    static let hatchSpacing = CadenceSpace.s6
    static let hatchStripe = CadenceSpace.s6 / 2
    static let hatchFill = 0.4
    static let hatchStripeOpacity = 0.85
    /// Calendar cells.
    static let cell = CadenceSize.controlToolbar
    static let cellGap = CadenceSpace.s4
    static let cellRing = CadenceSpace.s2
    static let cellDash: CGFloat = CadenceSpace.s4
    /// The split bar.
    static let split = CadenceSpace.s48 + CadenceSpace.s40
    static let splitGap = CadenceSpace.s2
    /// Slip reason bars.
    static let zone = CadenceSize.chip
    static let zoneMin = CadenceSpace.s32
    /// The fills of the slip bars after the first: brand mixed toward the track (prototype: 100, 84, 76).
    static let zoneMix = [1.0, 0.84, 0.76]
    /// Day shape.
    static let shapeTrack = CadenceSpace.s12
    static let shapeLabel = CadenceSpace.s32
    /// Strata: a layer is this tall plus this much per count, so thickness follows the count.
    static let layerBase = CadenceSpace.s20
    static let layerUnit = CadenceSpace.s8
    static let layerGap = CadenceSpace.s2
    static let strataMax = CadenceSpace.s48 * 4
    /// Count tiles.
    static let tileHeight = CadenceSpace.s48 + CadenceSpace.s32
    static let swatch = CadenceSpace.s8
    /// The table twin.
    static let tableRow = CadenceSize.taskRow - CadenceSpace.s12
    /// Increase Contrast gives band and hatched fills an edge.
    static let edge = CadenceStroke.hair
    static let edgeOpacity = 0.6
}

/// Formatting shared by the charts and the chapters.
enum ChartText {
    static let unknown = "-"

    static func value(_ value: Int?) -> String { value.map(String.init) ?? unknown }

    /// A share as a whole percentage, by the rule every share in Cadence follows. Nil when there is nothing to share.
    static func percent(_ done: Int?, of total: Int?) -> Int? {
        guard let done, let total, total > 0 else { return nil }
        return GenAIMetrics.percent(Int64(done), of: Int64(total))
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// "1 PR", "4 PRs".
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
    }
}

/// Dates as the system locale writes them (section 6.6): "5 Oct", "26 to 29 Oct" in sentences, "26 - 29 Oct" in
/// compact labels. Weeks start Monday.
public struct ChartDates: Sendable {
    public let locale: Locale

    public init(locale: Locale) {
        self.locale = locale
    }

    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    static func date(_ day: LocalDate) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? .distantPast
    }

    private func format(_ day: LocalDate, _ template: String) -> String { format(Self.date(day), template) }

    /// "5 Oct".
    public func short(_ day: LocalDate) -> String { format(day, "dMMM") }
    /// "Mon".
    public func weekday(_ day: LocalDate) -> String { format(day, "EEE") }
    /// "Mon 5 Oct".
    public func weekdayShort(_ day: LocalDate) -> String { format(day, "EEEdMMM") }
    /// "October".
    public func month(_ day: LocalDate) -> String { format(day, "MMMM") }
    /// The day of the month as printed in a calendar cell.
    public func dayNumber(_ day: LocalDate) -> String { format(day, "d") }

    /// "26 to 29 Oct", or "28 Sep to 4 Oct" across months. One day reads as itself.
    public func range(_ from: LocalDate, _ to: LocalDate) -> String { joined(from, to, " to ") }

    /// "26 - 29 Oct", for compact labels.
    public func compactRange(_ from: LocalDate, _ to: LocalDate) -> String { joined(from, to, " - ") }

    private func joined(_ from: LocalDate, _ to: LocalDate, _ separator: String) -> String {
        guard from != to else { return short(from) }
        let start = from.year == to.year && from.month == to.month ? dayNumber(from) : short(from)
        return start + separator + short(to)
    }

    /// The ISO week number of the week holding `day`: weeks start Monday.
    public static func isoWeek(_ day: LocalDate) -> Int {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = utc
        return calendar.component(.weekOfYear, from: date(day))
    }

    /// The full weekday name, for sentences: "Monday".
    public func weekdayName(_ weekday: Weekday) -> String { format(Self.sample(weekday), "EEEE") }

    /// The short weekday name: "Mon".
    public func weekdayShortName(_ weekday: Weekday) -> String { format(Self.sample(weekday), "EEE") }

    /// Noon UTC on a day that falls on `weekday`: 5 January 1970 was a Monday, and Monday is index 0.
    private static func sample(_ weekday: Weekday) -> Date {
        let day: TimeInterval = 86_400
        return Date(timeIntervalSince1970: (4 + Double(Weekday.allCases.firstIndex(of: weekday) ?? 0)) * day + day / 2)
    }

    private func format(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = Self.utc
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

/// Diagonal stripes for partial weeks.
struct Hatch: Shape {
    var spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

/// A bar's fill: solid, or hatched for a partial week. Increase Contrast adds an edge to the hatched fill.
struct BarFill<S: InsettableShape>: View {
    let shape: S
    let color: Color
    let hatched: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if hatched {
            shape.fill(color.opacity(ChartMetrics.hatchFill))
                .overlay(
                    Hatch(spacing: ChartMetrics.hatchSpacing)
                        .stroke(color.opacity(ChartMetrics.hatchStripeOpacity), lineWidth: ChartMetrics.hatchStripe)
                        .clipShape(shape)
                )
                .overlay(shape.strokeBorder(contrast == .increased ? color : .clear, lineWidth: ChartMetrics.edge))
        } else {
            shape.fill(color)
        }
    }
}

/// A chart reads to VoiceOver as its one sentence.
struct ChartAccessibility: ViewModifier {
    let summary: String

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
            .accessibilityAddTraits(.isImage)
    }
}

extension View {
    func chartAccessibility(_ summary: String) -> some View { modifier(ChartAccessibility(summary: summary)) }
}

/// A chart's table twin: heads in the label role, rows of tabular figures, hairlines between them.
public struct ChartTableView: View {
    let table: ChartTable

    public init(_ table: ChartTable) {
        self.table = table
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: CadenceSpace.s8, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in
                    Text(column)
                        .cadenceType(ChartType.tableHead)
                        .foregroundStyle(CadenceColor.ink3.color)
                        .frame(maxWidth: index == table.columns.count - 1 ? .infinity : nil, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .frame(minHeight: ChartMetrics.tableRow, alignment: .leading)
            rule
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                        Text(cell)
                            .cadenceType(ChartType.tableCell)
                            .foregroundStyle(CadenceColor.ink.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: index == row.count - 1 ? .infinity : nil, alignment: .leading)
                    }
                }
                .frame(minHeight: ChartMetrics.tableRow, alignment: .leading)
                rule
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table")
    }

    private var rule: some View {
        Rectangle()
            .fill(CadenceColor.line.color)
            .frame(height: CadenceStroke.hair)
            .gridCellUnsizedAxes(.horizontal)
    }
}

/// The quiet line under a chart, such as "Hatched weeks are partial."
struct ChartHint: View {
    let text: String

    var body: some View {
        Text(text)
            .cadenceType(ChartType.hint)
            .foregroundStyle(CadenceColor.ink3.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }
}
