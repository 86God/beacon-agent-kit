import SwiftUI

public struct BeaconAgentMessageView: View {
    public let markdown: String
    public let isFinished: Bool
    public let activities: [BeaconAgentActivityItem]

    public init(
        markdown: String,
        isFinished: Bool,
        activities: [BeaconAgentActivityItem] = []
    ) {
        self.markdown = markdown
        self.isFinished = isFinished
        self.activities = activities
    }

    public var body: some View {
        let presentation = BeaconIncrementalMarkdown.parse(markdown, isFinished: isFinished)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(activities) { BeaconAgentActivityView(item: $0) }
            ForEach(Array(presentation.committed.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            if let provisional = presentation.provisionalPlainText {
                Text(provisional)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockView(_ block: BeaconMarkdownBlock) -> AnyView {
        switch block {
        case let .richText(markdown):
            let attributed = (try? AttributedString(
                markdown: markdown,
                options: .init(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )) ?? AttributedString(markdown)
            return AnyView(Text(attributed).fixedSize(horizontal: false, vertical: true))
        case let .code(language, content):
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    if let language { Text(language).font(.caption).foregroundStyle(.secondary) }
                    ScrollView(.horizontal) {
                        Text(content).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            )
        case let .table(headers, rows):
            return AnyView(
                VStack(spacing: 0) {
                    tableRow(headers, emphasized: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Divider()
                        tableRow(row, emphasized: false)
                    }
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            )
        case .divider:
            return AnyView(Divider())
        }
    }

    private func tableRow(_ cells: [String], emphasized: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .font(emphasized ? .caption.weight(.semibold) : .caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
    }
}
