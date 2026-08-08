import SwiftUI
import BeaconAgentCore

public enum BeaconAgentActivityStatus: String, Equatable, Sendable {
    case pending, running, completed, failed
}

public struct BeaconAgentActivityItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let status: BeaconAgentActivityStatus

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        status: BeaconAgentActivityStatus
    ) {
        self.id = id
        self.title = BeaconRedactor.displayText(title)
        self.detail = BeaconRedactor.optionalDisplayText(detail)
        self.status = status
    }
}

public struct BeaconAgentActivityView: View {
    public let item: BeaconAgentActivityItem

    public init(item: BeaconAgentActivityItem) {
        self.item = item
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.medium))
                if let detail = item.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}
