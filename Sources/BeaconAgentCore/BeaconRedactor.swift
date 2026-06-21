import Foundation

public enum BeaconRedactor {
    public static func optionalDisplayText(_ value: String?) -> String? {
        let redacted = displayText(value ?? "")
        return redacted.isEmpty ? nil : redacted
    }

    public static func displayText(_ value: String) -> String {
        redactedText(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func redactedText(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+"#,
                with: "[image data redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"base64,[A-Za-z0-9+/=]{8,}"#,
                with: "base64,[image data redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?:sk|ak|pk|rk)-[A-Za-z0-9_-]{20,}"#,
                with: "[secret redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<!\d)1[3-9]\d{9}(?!\d)"#,
                with: "[phone redacted]",
                options: .regularExpression
            )
    }
}
