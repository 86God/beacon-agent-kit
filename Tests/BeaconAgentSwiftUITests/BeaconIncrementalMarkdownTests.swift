import Testing
@testable import BeaconAgentSwiftUI

struct BeaconIncrementalMarkdownTests {
    @Test
    func finishedMarkdownRecognizesRichTextCodeTableAndDivider() {
        let source = """
        ## 今日建议

        - **动作**：查看[哑铃推举](https://example.com)

        ```swift
        let sets = 4
        ```

        | 动作 | 组数 |
        | --- | --- |
        | 哑铃推举 | 4 |

        ---
        """

        let result = BeaconIncrementalMarkdown.parse(source, isFinished: true)

        #expect(result.provisionalMarkdown == nil)
        #expect(result.committed.contains(.code(language: "swift", content: "let sets = 4")))
        #expect(result.committed.contains(.table(headers: ["动作", "组数"], rows: [["哑铃推举", "4"]])))
        #expect(result.committed.contains(.divider))
        #expect(result.committed.contains { block in
            if case let .richText(markdown) = block {
                return markdown.contains("**动作**") && markdown.contains("[哑铃推举]")
            }
            return false
        })
    }

    @Test
    func completedBlocksRenderBeforeIncompleteTail() {
        let source = "## 今日建议\n\n第一段完成。\n\n- **动作**：哑铃推"

        let result = BeaconIncrementalMarkdown.parse(source, isFinished: false)

        #expect(result.committed == [
            .richText("## 今日建议"),
            .richText("第一段完成。")
        ])
        #expect(result.provisionalMarkdown == "- **动作**：哑铃推")
        #expect(result.provisionalPlainText == "• 动作：哑铃推")
    }

    @Test
    func closedTableRowsCommitWhilePartialRowStaysProvisional() {
        let source = """
        | 动作 | 组数 |
        | --- | --- |
        | 哑铃推举 | 4 |
        | 侧平举
        """

        let result = BeaconIncrementalMarkdown.parse(source, isFinished: false)

        #expect(result.committed == [.table(headers: ["动作", "组数"], rows: [["哑铃推举", "4"]])])
        #expect(result.provisionalPlainText == "侧平举")
    }

    @Test
    func incompleteCodeFenceRemainsOnlyInProvisionalTail() {
        let source = "准备完成。\n\n```swift\nlet sets ="

        let result = BeaconIncrementalMarkdown.parse(source, isFinished: false)

        #expect(result.committed == [.richText("准备完成。")])
        #expect(result.provisionalMarkdown == "```swift\nlet sets =")
        #expect(result.provisionalPlainText == "let sets =")
    }

    @Test
    func finalizationDoesNotRestylePreviouslyCommittedBlocks() {
        let partial = BeaconIncrementalMarkdown.parse(
            "## 计划\n\n第一段。\n\n- 动作",
            isFinished: false
        )
        let finished = BeaconIncrementalMarkdown.parse(
            "## 计划\n\n第一段。\n\n- 动作：推举",
            isFinished: true
        )

        #expect(Array(finished.committed.prefix(partial.committed.count)) == partial.committed)
    }

    @Test
    func activitySummariesAreRedactedBeforeRendering() {
        let item = BeaconAgentActivityItem(
            id: "activity-1",
            title: "查询 13800138000",
            detail: "sk-123456789012345678901234567890",
            status: .running
        )

        #expect(item.title == "查询 [phone redacted]")
        #expect(item.detail == "[secret redacted]")
    }
}
