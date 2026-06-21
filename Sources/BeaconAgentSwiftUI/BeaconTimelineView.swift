import SwiftUI
import BeaconAgentCore

public struct BeaconTimelineView: View {
    public let state: BeaconTimelineState

    public init(state: BeaconTimelineState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(state.messages) { message in
                    Text(message.text)
                        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                }
                ForEach(state.toolRuns) { toolRun in
                    BeaconToolRunView(toolRun: toolRun)
                }
                BeaconCardStackView(cards: state.cards)
            }
            .padding()
        }
    }
}
