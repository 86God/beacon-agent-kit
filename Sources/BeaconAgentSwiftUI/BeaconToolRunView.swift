import SwiftUI
import BeaconAgentCore

public struct BeaconToolRunView: View {
    public let toolRun: BeaconToolRun

    public init(toolRun: BeaconToolRun) {
        self.toolRun = toolRun
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
            VStack(alignment: .leading, spacing: 4) {
                Text(toolRun.title).font(.headline)
                Text(toolRun.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var iconName: String {
        switch toolRun.status {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .needsReview: "slider.horizontal.3"
        case .cancelled: "xmark.circle"
        }
    }
}
