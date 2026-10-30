/// Three-letter weekday as used in config `workdays`.
public enum Weekday: String, Sendable, Hashable, CaseIterable, Codable {
    case mon, tue, wed, thu, fri, sat, sun
}
