import SwiftUI
import BeaconAgentCore
import BeaconAgentA2UI

public struct BeaconGenericSurfaceView: View {
    public let surface: BeaconA2UISurface
    public let catalog: BeaconSurfaceRendererCatalog
    public let onAction: (BeaconA2UIActionEnvelope) -> Void

    public init(
        surface: BeaconA2UISurface,
        catalog: BeaconSurfaceRendererCatalog = .generic,
        onAction: @escaping (BeaconA2UIActionEnvelope) -> Void = { _ in }
    ) {
        self.surface = surface
        self.catalog = catalog
        self.onAction = onAction
    }

    public var body: some View {
        render(componentID: surface.rootComponentID)
    }

    private func render(componentID: String) -> AnyView {
        guard let component = surface.components[componentID] else {
            return AnyView(safeFallback("Content unavailable"))
        }
        guard catalog.supports(component.type) else {
            return AnyView(safeFallback(component.properties.string("text") ?? "Unsupported content"))
        }
        switch component.type {
        case "Text":
            return AnyView(
                Text(component.properties.string("text") ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        case "Row":
            return AnyView(
                HStack(alignment: .top, spacing: 12) {
                    ForEach(component.children, id: \.self) { render(componentID: $0) }
                }
            )
        case "Column", "List", "Table":
            return AnyView(
                VStack(alignment: .leading, spacing: component.type == "Table" ? 8 : 12) {
                    ForEach(component.children, id: \.self) { render(componentID: $0) }
                }
            )
        case "Card":
            return AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(component.children, id: \.self) { render(componentID: $0) }
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            )
        case "Button":
            return AnyView(actionButton(component, fallbackLabel: "Continue"))
        case "Metric":
            return AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    Text(component.properties.string("label") ?? "Metric")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(component.properties.string("value") ?? "—")
                        .font(.title3.weight(.semibold))
                }
            )
        case "Notice":
            return AnyView(statusRow(component, symbol: "info.circle.fill", color: .blue))
        case "Error":
            return AnyView(statusRow(component, symbol: "exclamationmark.triangle.fill", color: .red))
        case "Retry":
            return AnyView(actionButton(component, fallbackLabel: "Retry"))
        case "Approval":
            return AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    Text(component.properties.string("title") ?? "Confirmation required")
                        .font(.headline)
                    Text(component.properties.string("summary") ?? "")
                        .foregroundStyle(.secondary)
                    HStack {
                        ForEach(component.actions, id: \.id) { action in
                            approvalButton(action, component: component)
                        }
                    }
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            )
        case "Receipt":
            return AnyView(statusRow(component, symbol: "checkmark.seal.fill", color: .green))
        default:
            return AnyView(safeFallback(component.properties.string("text") ?? "Unsupported content"))
        }
    }

    private func actionButton(
        _ component: BeaconA2UIComponent,
        fallbackLabel: String
    ) -> some View {
        let label = component.properties.string("label") ?? fallbackLabel
        return Group {
            if catalog.actionsEnabled(for: component.type), let action = component.actions.first {
                Button(label) { send(action, from: component) }
                    .buttonStyle(.borderedProminent)
            } else {
                Text(label).foregroundStyle(.secondary)
            }
        }
    }

    private func approvalButton(
        _ action: BeaconA2UIAction,
        component: BeaconA2UIComponent
    ) -> AnyView {
        if action.name == "approve" {
            return AnyView(
                Button("Confirm") { send(action, from: component) }
                    .buttonStyle(.borderedProminent)
            )
        }
        return AnyView(
            Button("Cancel") { send(action, from: component) }
                .buttonStyle(.bordered)
        )
    }

    private func statusRow(
        _ component: BeaconA2UIComponent,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(component.properties.string("title") ?? component.type).font(.headline)
                Text(component.properties.string("message") ?? component.properties.string("summary") ?? "")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func safeFallback(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func send(_ action: BeaconA2UIAction, from component: BeaconA2UIComponent) {
        guard catalog.actionsEnabled(for: component.type) else { return }
        onAction(
            BeaconA2UIActionEnvelope(
                surfaceID: surface.id,
                componentID: component.id,
                actionID: action.id,
                name: action.name,
                payload: action.payload
            )
        )
    }
}

private extension Dictionary where Key == String, Value == BeaconJSONValue {
    func string(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else { return nil }
        return value
    }
}
