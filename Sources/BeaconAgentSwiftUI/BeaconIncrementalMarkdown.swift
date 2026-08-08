import Foundation
import BeaconAgentCore

public enum BeaconMarkdownBlock: Equatable, Sendable {
    case richText(String)
    case code(language: String?, content: String)
    case table(headers: [String], rows: [[String]])
    case divider
}

public struct BeaconIncrementalMarkdownPresentation: Equatable, Sendable {
    public let committed: [BeaconMarkdownBlock]
    public let provisionalMarkdown: String?
    public let provisionalPlainText: String?
}

public enum BeaconIncrementalMarkdown {
    public static func parse(
        _ source: String,
        isFinished: Bool
    ) -> BeaconIncrementalMarkdownPresentation {
        let redacted = BeaconRedactor.redactedText(source)
        if isFinished {
            return BeaconIncrementalMarkdownPresentation(
                committed: parseAll(redacted),
                provisionalMarkdown: nil,
                provisionalPlainText: nil
            )
        }
        let result = parseStable(redacted)
        return BeaconIncrementalMarkdownPresentation(
            committed: result.blocks,
            provisionalMarkdown: nonEmpty(result.tail),
            provisionalPlainText: nonEmpty(plainText(result.tail))
        )
    }

    private static func parseStable(_ source: String) -> (blocks: [BeaconMarkdownBlock], tail: String) {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [BeaconMarkdownBlock] = []
        var index = 0
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            if let fence = fenceStart(lines[index]) {
                if let closing = (index + 1..<lines.count).first(where: {
                    lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("```")
                }) {
                    let content = lines[(index + 1)..<closing].joined(separator: "\n")
                    blocks.append(.code(language: fence, content: content))
                    index = closing + 1
                    continue
                }
                return (blocks, lines[index...].joined(separator: "\n"))
            }
            if index + 1 < lines.count,
               isTableRow(lines[index]),
               isTableSeparator(lines[index + 1]) {
                let headers = cells(lines[index])
                var rows: [[String]] = []
                index += 2
                while index < lines.count, isTableRow(lines[index]) {
                    guard isCompleteTableRow(lines[index], columns: headers.count) else {
                        blocks.append(.table(headers: headers, rows: rows))
                        return (blocks, lines[index...].joined(separator: "\n"))
                    }
                    rows.append(normalize(cells(lines[index]), count: headers.count))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }
            if isDivider(lines[index]) {
                blocks.append(.divider)
                index += 1
                continue
            }
            if isHeading(lines[index]), index < lines.count - 1 {
                blocks.append(.richText(lines[index].trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            let start = index
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            let paragraph = lines[start..<index].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if index < lines.count || source.hasSuffix("\n") {
                if !paragraph.isEmpty { blocks.append(.richText(paragraph)) }
            } else {
                return (blocks, paragraph)
            }
        }
        return (blocks, "")
    }

    private static func parseAll(_ source: String) -> [BeaconMarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [BeaconMarkdownBlock] = []
        var text: [String] = []
        var index = 0

        func flush() {
            let value = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { blocks.append(.richText(value)) }
            text.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            if let language = fenceStart(lines[index]) {
                flush()
                if let closing = (index + 1..<lines.count).first(where: {
                    lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("```")
                }) {
                    blocks.append(
                        .code(
                            language: language,
                            content: lines[(index + 1)..<closing].joined(separator: "\n")
                        )
                    )
                    index = closing + 1
                } else {
                    text.append(contentsOf: lines[index...])
                    index = lines.count
                }
                continue
            }
            if index + 1 < lines.count,
               isTableRow(lines[index]),
               isTableSeparator(lines[index + 1]) {
                flush()
                let headers = cells(lines[index])
                index += 2
                var rows: [[String]] = []
                while index < lines.count, isTableRow(lines[index]) {
                    rows.append(normalize(cells(lines[index]), count: headers.count))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }
            if isDivider(lines[index]) {
                flush()
                blocks.append(.divider)
                index += 1
                continue
            }
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                text.append(lines[index])
            }
            index += 1
        }
        flush()
        return blocks
    }

    private static func plainText(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines).compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || isTableSeparator(trimmed) { return nil }
            if trimmed.contains("|") {
                let values = cells(trimmed)
                return values.isEmpty ? nil : values.joined(separator: " · ")
            }
            var value = trimmed
            value = value.replacingOccurrences(
                of: #"^#{1,6}\s*"#,
                with: "",
                options: .regularExpression
            )
            value = value.replacingOccurrences(
                of: #"^[-*+]\s+"#,
                with: "• ",
                options: .regularExpression
            )
            value = value.replacingOccurrences(
                of: #"^\d+[.)]\s+"#,
                with: "",
                options: .regularExpression
            )
            value = value.replacingOccurrences(
                of: #"\[([^\]]+)\]\([^\)]*\)"#,
                with: "$1",
                options: .regularExpression
            )
            for token in ["**", "__", "~~", "`", "*"] {
                value = value.replacingOccurrences(of: token, with: "")
            }
            return value
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fenceStart(_ line: String) -> String?? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return .some(language.isEmpty ? nil : language)
    }

    private static func isHeading(_ line: String) -> Bool {
        line.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) != nil
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first, "-_*".contains(marker) else {
            return false
        }
        return compact.allSatisfy { $0 == marker }
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && cells(line).count >= 2
    }

    private static func isCompleteTableRow(_ line: String, columns: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix("|") && cells(line).count >= columns
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let values = cells(line)
        return values.count >= 2 && values.allSatisfy { value in
            let compact = value.replacingOccurrences(of: ":", with: "")
            return compact.count >= 3 && compact.allSatisfy { $0 == "-" }
        }
    }

    private static func cells(_ line: String) -> [String] {
        var values = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if values.first?.isEmpty == true { values.removeFirst() }
        if values.last?.isEmpty == true { values.removeLast() }
        return values.filter { !$0.isEmpty }
    }

    private static func normalize(_ row: [String], count: Int) -> [String] {
        if row.count >= count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
