import Foundation

/// RFC 4180 CSV: a header row, then one object per row keyed by header. Quoted fields may hold commas, quotes
/// (doubled) and line breaks. A UTF-8 byte order mark is dropped. Every value is a string.
enum CSVReader {
    struct Row {
        /// 1-based line where the row starts.
        var line: Int
        var value: Result<JSONValue, CadenceError>
    }

    static func rows(_ bytes: [UInt8]) throws(CadenceError) -> [Row] {
        guard var text = String(validating: bytes, as: UTF8.self) else { throw .validation("the CSV is not valid UTF-8") }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let records = try split(text)
        guard let header = records.first else { throw .validation("the CSV has no header row") }
        let names = header.fields.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !names.contains(where: \.isEmpty) else { throw .validation("the CSV header has an empty column name") }
        guard Set(names).count == names.count else { throw .validation("the CSV header names a column twice") }
        return records.dropFirst().compactMap { record -> Row? in
            if record.fields == [""] { return nil }  // a blank line
            guard record.fields.count == names.count else {
                return Row(line: record.line, value: .failure(.validation("has \(record.fields.count) columns, the header has \(names.count)")))
            }
            var object: [String: JSONValue] = [:]
            for (name, field) in zip(names, record.fields) { object[name] = .string(field) }
            return Row(line: record.line, value: .success(.object(object)))
        }
    }

    private struct Record {
        var line: Int
        var fields: [String]
    }

    private static func split(_ text: String) throws(CadenceError) -> [Record] {
        var records: [Record] = []
        var fields: [String] = []
        var field = ""
        var quoted = false
        var atFieldStart = true
        var line = 1
        var recordLine = 1
        var scalars = Array(text.unicodeScalars)[...]
        while let c = scalars.popFirst() {
            if quoted {
                if c == "\"" {
                    if scalars.first == "\"" {
                        field.unicodeScalars.append("\"")
                        scalars.removeFirst()
                    } else {
                        quoted = false
                    }
                } else {
                    if c == "\n" { line += 1 }
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"" where atFieldStart:
                quoted = true
                atFieldStart = false
            case ",":
                fields.append(field)
                field = ""
                atFieldStart = true
            case "\r" where scalars.first == "\n":
                continue
            case "\n", "\r":
                fields.append(field)
                records.append(Record(line: recordLine, fields: fields))
                fields = []
                field = ""
                atFieldStart = true
                line += 1
                recordLine = line
            default:
                field.unicodeScalars.append(c)
                atFieldStart = false
            }
        }
        guard !quoted else { throw .validation("the CSV ends inside a quoted field") }
        if !field.isEmpty || !fields.isEmpty {
            fields.append(field)
            records.append(Record(line: recordLine, fields: fields))
        }
        return records
    }
}
