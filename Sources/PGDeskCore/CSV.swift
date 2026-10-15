import Foundation

/// CSV in the style of Postgres `COPY … (format csv, header)`: fields with a comma, quote,
/// CR or LF are quoted, NULL is an empty unquoted field and an empty string is `""`.
public enum CSV {
    public static func encode(columns: [String], rows: [[String?]]) -> String {
        var out = columns.map { field($0) }.joined(separator: ",")
        out += "\n"
        for row in rows {
            out += row.map { $0.map(field) ?? "" }.joined(separator: ",")
            out += "\n"
        }
        return out
    }

    static func field(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
