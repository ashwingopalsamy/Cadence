/// The JSONPath subset maps use (docs/SPEC.md section 10.5): `$`, `.key`, `['key']`, `[n]` and `[*]`.
/// No filters, no recursion and no scripts, so a map can only select.
public struct MapPath: Sendable, Equatable, CustomStringConvertible {
    public enum Step: Sendable, Equatable {
        case key(String)
        case index(Int)
        case all
    }

    public let steps: [Step]
    public let description: String

    public init(_ text: String) throws(CadenceError) {
        let b = Array(text.utf8)
        guard b.first == 0x24 else { throw .validation("path '\(text)': must start with $") }
        var i = 1
        var steps: [Step] = []
        func fail(_ why: String) -> CadenceError { .validation("path '\(text)': \(why)") }
        while i < b.count {
            switch b[i] {
            case 0x2E:  // .key
                i += 1
                let start = i
                while i < b.count, b[i] != 0x2E, b[i] != 0x5B { i += 1 }
                guard i > start else { throw fail("a dot must be followed by a key") }
                let key = String(decoding: b[start..<i], as: UTF8.self)
                guard key.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" || $0 == "-" })
                else { throw fail("use ['\(key)'] for a key with other characters") }
                steps.append(.key(key))
            case 0x5B:  // [ ... ]
                i += 1
                guard i < b.count else { throw fail("unclosed [") }
                if b[i] == 0x27 {
                    i += 1
                    var key: [UInt8] = []
                    while i < b.count, b[i] != 0x27 {
                        if b[i] == 0x5C, i + 1 < b.count { i += 1 }
                        key.append(b[i])
                        i += 1
                    }
                    guard i + 1 < b.count, b[i] == 0x27, b[i + 1] == 0x5D else { throw fail("unclosed ['") }
                    i += 2
                    steps.append(.key(String(decoding: key, as: UTF8.self)))
                } else if b[i] == 0x2A {
                    guard i + 1 < b.count, b[i + 1] == 0x5D else { throw fail("[* must close with ]") }
                    i += 2
                    steps.append(.all)
                } else {
                    let start = i
                    while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
                    guard i > start, i - start <= 9, i < b.count, b[i] == 0x5D, let n = Int(String(decoding: b[start..<i], as: UTF8.self))
                    else { throw fail("an index must be a whole number in [ ]") }
                    i += 1
                    steps.append(.index(n))
                }
            default:
                throw fail("unexpected '\(String(decoding: [b[i]], as: UTF8.self))'; filters and scripts are not supported")
            }
        }
        self.steps = steps
        self.description = text
    }

    public var hasWildcard: Bool { steps.contains(.all) }

    /// Every value the path selects. A missing key or index selects nothing.
    public func select(_ root: JSONValue) -> [JSONValue] {
        var current = [root]
        for step in steps {
            var next: [JSONValue] = []
            for value in current {
                switch step {
                case .key(let key):
                    if let found = value.objectValue?[key] { next.append(found) }
                case .index(let n):
                    if let array = value.arrayValue, n < array.count { next.append(array[n]) }
                case .all:
                    if let array = value.arrayValue {
                        next.append(contentsOf: array)
                    } else if let object = value.objectValue {
                        next.append(contentsOf: object.keys.sorted().compactMap { object[$0] })
                    }
                }
            }
            current = next
        }
        return current
    }
}
