import Foundation

public enum TokenCountFormatter {
    public static func chinese(_ value: Int) -> String {
        let decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
            ?? .zero
        let negative = decimal < .zero
        let magnitude = negative ? -decimal : decimal

        let quantity: String
        if magnitude < 10_000 {
            quantity = exactMagnitude(String(value.magnitude))
        } else if magnitude < 100_000_000 {
            quantity = compact(magnitude / 10_000, maximumFractionDigits: 4) + "万"
        } else if magnitude < 1_000_000_000_000 {
            quantity = compact(magnitude / 100_000_000, maximumFractionDigits: 2) + "亿"
        } else {
            quantity = compact(
                magnitude / 1_000_000_000_000,
                maximumFractionDigits: 2
            ) + "万亿"
        }

        return negative ? "-\(quantity)" : quantity
    }

    public static func exact(_ value: Int) -> String {
        let raw = String(value)
        let negative = raw.hasPrefix("-")
        let digits = negative ? String(raw.dropFirst()) : raw
        let grouped = exactMagnitude(digits)
        return negative ? "-\(grouped)" : grouped
    }

    public static func accessibility(_ value: Int) -> String {
        "\(exact(value)) Tokens（约 \(chinese(value))）"
    }

    private static func compact(
        _ value: Decimal,
        maximumFractionDigits: Int
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    private static func exactMagnitude(_ digits: String) -> String {
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset.isMultiple(of: 3) {
                result.append(",")
            }
            result.append(character)
        }
        return String(result.reversed())
    }
}
