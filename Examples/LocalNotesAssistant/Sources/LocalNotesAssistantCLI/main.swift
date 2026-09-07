import Foundation
import LocalNotesAssistant

private struct OneLineDraftModel: LocalNotesModel {
    func makeDraft(
        prompt: String,
        existingNotes: [LocalNote]
    ) async throws -> LocalNotesModelDraft {
        LocalNotesModelDraft(title: "Assistant note", body: prompt)
    }
}

@main
struct LocalNotesAssistantCLI {
    static func main() async throws {
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        guard !prompt.isEmpty else {
            print("Usage: swift run local-notes-assistant <note text>")
            return
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local-notes-assistant", isDirectory: true)
        let session = try LocalNotesAssistantSession(
            rootURL: root,
            accountID: "local-account",
            deviceID: "local-device",
            profileID: "local-profile",
            model: OneLineDraftModel()
        )
        let draft = try await session.begin(prompt: prompt)
        print("Draft: \(draft.title)\n\(draft.body)\nConfirm? [y/N]")
        guard readLine()?.lowercased() == "y" else {
            print("Not saved.")
            return
        }
        let note = try await session.confirm(draft)
        print("Saved note \(note.id).")
    }
}
