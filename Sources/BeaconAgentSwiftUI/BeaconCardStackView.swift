import SwiftUI
import BeaconAgentCore

/// Generic SwiftUI stack for `BeaconCardEnvelope` values.
public struct BeaconCardStackView: View {
    public let cards: [BeaconCardEnvelope]

    public init(cards: [BeaconCardEnvelope]) {
        self.cards = cards
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(cards) { card in
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(.headline)
                    Text(card.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
