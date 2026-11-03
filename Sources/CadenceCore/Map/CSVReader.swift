import Foundation

/// RFC 4180 CSV: a header row, then one object per row keyed by header. Quoted fields may hold commas, quotes
/// (doubled) and line breaks. A quote opens a field only at its start, and nothing may follow the closing quote
/// but a comma or a line break. A UTF-8 byte order mark is dropped. Every value is a string.
enum CSVReader {
    /// More columns than this is not a usage table, and a row must not cost a string for every comma in it.
    static let maxColumns = 256

    struct Row {
        /// 1-based line where the row starts.
        var line: Int
        var value: Result<JSONValue, CadenceError>
    }

    /// At most `limit + 1` rows are read, so a caller can tell there are too many without reading the rest.
    static func rows(_ bytes: [UInt8], limit: Int = EnvelopeReader.maxRecords) throws(CadenceError) -> [Row] {
        guard var text = String(validating: bytes, as: UTF8.self) else { throw .validation("the CSV is not valid UTF-8") }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let records = try split(text, upTo: limit + 2)  // the header, then `limit` rows and one more
        guard let header = records.first else { throw .validation("the CSV has no header row") }
        guard header.columns <= maxColumns else { throw .validation("the CSV has more than \(maxColumns) columns") }
        let names = header.fields.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !names.contains(where: \.isEmpty) else { throw .validation("the CSV header has an empty column name") }
        guard Set(names).count == names.count else { throw .validation("the CSV header names a column twice") }
        return records.dropFirst().map { record -> Row in
            guard record.columns == names.count else {
                return Row(line: record.line, value: .failure(.validation("has \(record.columns) columns, the header has \(names.count)")))
            }
            var object: [String: JSONValue] = [:]
            for (name, field) in zip(names, record.fields) { object[name] = .string(field) }
            return Row(line: record.line, value: .success(.object(object)))
        }
    }

    private struct Record {
        var line: Int
        /// The first `maxColumns + 1` fields; the rest are counted and dropped.
        var fields: [String]
        var columns: Int
    }

    /// Splits `text` into records, skipping blank lines, and stops once `limit` records are read.
    private static func split(_ text: String, upTo limit: Int) throws(CadenceError) -> [Record] {
        var records: [Record] = []
        var fields: [String] = []
        var columns = 0
        var field = ""
        var quoted = false
        var closed = false  // just past a closing quote
        var atFieldStart = true
        var line = 1
        var recordLine = 1
        var scalars = Array(text.unicodeScalars)[...]

        func endField() {
            columns += 1
            if fields.count <= maxColumns { fields.append(field) }
            field = ""
            atFieldStart = true
            closed = false
        }
        func malformed(_ why: String) -> CadenceError { .validation("the CSV is malformed at line \(line): \(why)") }

        while let c = scalars.popFirst() {
            if quoted {
                if c == "\"" {
                    if scalars.first == "\"" {
                        field.unicodeScalars.append("\"")
                        scalars.removeFirst()
                    } else {
                        quoted = false
                        closed = true
                    }
                } else {
                    if c == "\n" || (c == "\r" && scalars.first != "\n") { line += 1 }
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"":
                guard atFieldStart else { throw malformed("a quote inside an unquoted field") }
                quoted = true
                atFieldStart = false
            case ",":
                endField()
            case "\r" where scalars.first == "\n":
                continue
            case "\n", "\r":
                // A blank line is no record at all, so a file of line breaks costs nothing.
                if columns > 0 || !field.isEmpty {
                    endField()
                    records.append(Record(line: recordLine, fields: fields, columns: columns))
                    if records.count >= limit { return records }
                }
                fields = []
                columns = 0
                field = ""
                atFieldStart = true
                closed = false
                line += 1
                recordLine = line
            default:
                guard !closed else { throw malformed("text after a closing quote") }
                field.unicodeScalars.append(c)
                atFieldStart = false
            }
        }
        guard !quoted else { throw .validation("the CSV ends inside a quoted field") }
        if columns > 0 || !field.isEmpty {
            endField()
            records.append(Record(line: recordLine, fields: fields, columns: columns))
        }
        return records
    }
}
