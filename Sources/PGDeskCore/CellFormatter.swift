import Foundation
import PostgresNIO

/// Turns binary-format cells into display strings. `nil` means SQL NULL.
enum CellFormatter {
    static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func format(_ cell: PostgresCell) -> String? {
        guard var bytes = cell.bytes else { return nil }
        if cell.format == .text {
            return bytes.readString(length: bytes.readableBytes)
        }
        do {
            return try formatBinary(cell)
        } catch {
            return fallback(cell)
        }
    }

    private static func formatBinary(_ cell: PostgresCell) throws -> String {
        switch cell.dataType {
        case .bool:
            return try cell.decode(Bool.self) ? "true" : "false"
        case .int2:
            return String(try cell.decode(Int16.self))
        case .int4:
            return String(try cell.decode(Int32.self))
        case .int8:
            return String(try cell.decode(Int64.self))
        case .oid:
            guard var bytes = cell.bytes, let value = bytes.readInteger(as: UInt32.self) else {
                throw PostgresDecodingError.Code.failure
            }
            return String(value)
        case .float4:
            return String(try cell.decode(Float.self))
        case .float8:
            return String(try cell.decode(Double.self))
        case .numeric:
            return try formatNumeric(cell)
        case .timestamp, .timestamptz:
            return timestampFormatter.string(from: try cell.decode(Date.self))
        case .date:
            return dateFormatter.string(from: try cell.decode(Date.self))
        case .uuid:
            return try cell.decode(UUID.self).uuidString.lowercased()
        case .bytea:
            let data = cell.bytes.map { Array($0.readableBytesView) } ?? []
            return "\\x" + data.map { String(format: "%02x", $0) }.joined()
        case .interval:
            return try formatInterval(cell)
        case .textArray, .varcharArray, .nameArray, .bpcharArray:
            return arrayLiteral(try cell.decode([String].self))
        case .int2Array:
            return arrayLiteral(try cell.decode([Int16].self).map(String.init))
        case .int4Array:
            return arrayLiteral(try cell.decode([Int32].self).map(String.init))
        case .int8Array:
            return arrayLiteral(try cell.decode([Int64].self).map(String.init))
        case .boolArray:
            return arrayLiteral(try cell.decode([Bool].self).map { $0 ? "t" : "f" })
        case .uuidArray:
            return arrayLiteral(try cell.decode([UUID].self).map { $0.uuidString.lowercased() })
        default:
            // text, varchar, name, json, jsonb, xml and enums all arrive as UTF-8 text.
            let string = try cell.decode(String.self)
            guard isPrintable(string) else { throw PostgresDecodingError.Code.typeMismatch }
            return string
        }
    }

    /// Binary numeric: ndigits, weight, sign, dscale, then base-10000 digits. Formatted exactly
    /// like psql, keeping the declared scale (10.00 stays 10.00) and arbitrary precision.
    private static func formatNumeric(_ cell: PostgresCell) throws -> String {
        guard var bytes = cell.bytes,
              let ndigits = bytes.readInteger(as: Int16.self),
              let weight = bytes.readInteger(as: Int16.self),
              let sign = bytes.readInteger(as: UInt16.self),
              let dscale = bytes.readInteger(as: UInt16.self) else {
            throw PostgresDecodingError.Code.failure
        }
        switch sign {
        case 0xC000: return "NaN"
        case 0xD000: return "Infinity"
        case 0xF000: return "-Infinity"
        default: break
        }
        var digits: [Int16] = []
        for _ in 0..<max(0, Int(ndigits)) {
            guard let digit = bytes.readInteger(as: Int16.self) else { throw PostgresDecodingError.Code.failure }
            digits.append(digit)
        }
        func group(_ index: Int) -> Int16 { index >= 0 && index < digits.count ? digits[index] : 0 }

        var integer = ""
        if weight < 0 {
            integer = "0"
        } else {
            for index in 0...Int(weight) {
                integer += index == 0 ? String(group(index)) : String(format: "%04d", group(index))
            }
        }
        var result = (sign == 0x4000 ? "-" : "") + integer
        if dscale > 0 {
            var fraction = ""
            var index = Int(weight) + 1
            while fraction.count < Int(dscale) {
                fraction += String(format: "%04d", group(index))
                index += 1
            }
            result += "." + fraction.prefix(Int(dscale))
        }
        return result
    }

    /// Binary interval: int64 microseconds, int32 days, int32 months. Formatted like psql.
    private static func formatInterval(_ cell: PostgresCell) throws -> String {
        guard var bytes = cell.bytes,
              let micros = bytes.readInteger(as: Int64.self),
              let days = bytes.readInteger(as: Int32.self),
              let months = bytes.readInteger(as: Int32.self) else {
            throw PostgresDecodingError.Code.failure
        }
        var parts: [String] = []
        func unit(_ value: Int32, _ name: String) {
            if value != 0 { parts.append("\(value) \(name)\(abs(value) == 1 ? "" : "s")") }
        }
        unit(months / 12, "year")
        unit(months % 12, "mon")
        unit(days, "day")
        if micros != 0 || parts.isEmpty {
            let sign = micros < 0 ? "-" : ""
            let total = abs(micros)
            let seconds = total / 1_000_000, fraction = total % 1_000_000
            var time = String(format: "%@%02lld:%02lld:%02lld", sign, seconds / 3600, seconds / 60 % 60, seconds % 60)
            if fraction != 0 {
                time += String(format: ".%06lld", fraction).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            }
            parts.append(time)
        }
        return parts.joined(separator: " ")
    }

    private static func isPrintable(_ string: String) -> Bool {
        !string.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r" }
    }

    /// Last resort for types we don't decode (interval, inet, geometric, ...):
    /// show the bytes if they are readable text, otherwise the type name.
    private static func fallback(_ cell: PostgresCell) -> String {
        if var bytes = cell.bytes,
           let string = bytes.readString(length: bytes.readableBytes),
           isPrintable(string) {
            return string
        }
        return "<\((cell.dataType.knownSQLName ?? "oid \(cell.dataType.rawValue)").lowercased())>"
    }

    private static func arrayLiteral(_ items: [String]) -> String {
        "{" + items.joined(separator: ",") + "}"
    }
}
