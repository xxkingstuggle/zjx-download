import Foundation

/// Parses the three date forms HTTP recipients are required to accept.
public enum HTTPDateParser {
    public static func parse(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

/// Formats byte sizes and rates using the unit base selected in Settings.
public enum ByteDisplayFormatter {
    public static func string(_ byteCount: Int64, unit: SizeUnit, suffix: String = "") -> String {
        let magnitude = abs(Double(byteCount))
        let base = unit.base
        var value = magnitude
        var index = 0
        while value >= base && index < unit.labels.count - 1 {
            value /= base
            index += 1
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value < 10 && index > 0 ? 1 : 0
        formatter.minimumFractionDigits = 0
        let rendered = formatter.string(from: NSNumber(value: value)) ?? String(Int64(value))
        let sign = byteCount < 0 ? "−" : ""
        return "\(sign)\(rendered) \(unit.labels[index])\(suffix)"
    }
}
