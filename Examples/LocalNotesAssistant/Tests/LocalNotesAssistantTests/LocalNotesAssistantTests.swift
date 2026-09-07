import Foundation
import Testing
import LocalNotesAssistant

@Suite("Independent LocalNotesAssistant consumer")
struct LocalNotesAssistantTests {
    @Test("read, draft, confirmation, commit and restart use the SDK contracts")
    func readDraftConfirmCommitAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalNotesAssistantTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = FixedDraftModel(
            draft: LocalNotesModelDraft(
                title: "Shopping",
                body: "Oats and blueberries"
            )
        )

        let first = try LocalNotesAssistantSession(
            rootURL: root,
            accountID: "account-a",
            deviceID: "device-a",
            profileID: "profile-a",
            model: model,
            now: { now }
        )
        let pending = try await first.begin(prompt: "Create a shopping note")
        #expect(try await first.notes().isEmpty)
        #expect(await model.receivedExistingNotes == [[]])
        let beforeRestart = try await first.restoredState(runID: pending.runID)
        #expect(beforeRestart.status == "waiting_approval")
        #expect(beforeRestart.pendingDraft == pending)

        let reopened = try LocalNotesAssistantSession(
            rootURL: root,
            accountID: "account-a",
            deviceID: "device-a",
            profileID: "profile-a",
            model: model,
            now: { now }
        )
        let restoredDraft = try #require(await reopened.pendingDraft(runID: pending.runID))
        let committed = try await reopened.confirm(restoredDraft)
        #expect(committed.title == "Shopping")
        #expect(try await reopened.notes() == [committed])

        let afterCommit = try LocalNotesAssistantSession(
            rootURL: root,
            accountID: "account-a",
            deviceID: "device-b",
            profileID: "profile-a",
            model: model,
            now: { now }
        )
        let restored = try await afterCommit.restoredState(runID: pending.runID)
        #expect(restored.status == "finished")
        #expect(restored.pendingDraft == nil)
        #expect(restored.pendingCommandCount == 0)
        #expect(restored.notes == [committed])
        #expect(restored.activeMemorySummaries == ["Last confirmed note: Shopping"])
        #expect(restored.eventTypes == [
            "run.started",
            "tool.start", "tool.result",
            "tool.start", "tool.result",
            "approval.requested", "approval.resolved",
            "tool.start", "tool.result",
            "receipt.committed", "run.finished"
        ])
    }

    @Test("the reusable SDK layers stay free of JianHao and Apple health UI dependencies")
    func reusableModulesHaveNoDomainImports() throws {
        var sdkRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { sdkRoot.deleteLastPathComponent() }
        let roots = [
            "Sources/BeaconAgentCore",
            "Sources/BeaconAgentMemory",
            "Sources/BeaconAgentPersistence"
        ]
        let forbidden = [
            "import JianHao", "import HealthKit", "import SwiftUI", "import UIKit",
            "JianHaoPoC", "FoodPhotoEstimate", "ExerciseDraftModel"
        ]

        for relativeRoot in roots {
            let directory = sdkRoot.appendingPathComponent(relativeRoot, isDirectory: true)
            let files = try #require(
                FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL }
                    .filter { $0.pathExtension == "swift" }
            )
            #expect(!files.isEmpty)
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    #expect(!source.contains(token), "\(relativeRoot) contains forbidden token \(token)")
                }
            }
        }
    }
}

private actor FixedDraftModel: LocalNotesModel {
    let draft: LocalNotesModelDraft
    private(set) var receivedExistingNotes: [[LocalNote]] = []

    init(draft: LocalNotesModelDraft) {
        self.draft = draft
    }

    func makeDraft(prompt: String, existingNotes: [LocalNote]) async throws -> LocalNotesModelDraft {
        receivedExistingNotes.append(existingNotes)
        return draft
    }
}
