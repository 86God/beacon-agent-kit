import Foundation

public struct BeaconSurfaceRendererCatalog: Equatable, Sendable {
    private let supportedTypes: Set<String>
    private let interactiveTypes: Set<String>

    public init(supportedTypes: Set<String>, interactiveTypes: Set<String>) {
        self.supportedTypes = supportedTypes
        self.interactiveTypes = interactiveTypes.intersection(supportedTypes)
    }

    public func supports(_ type: String) -> Bool {
        supportedTypes.contains(type)
    }

    public func actionsEnabled(for type: String) -> Bool {
        interactiveTypes.contains(type)
    }

    public static let generic = BeaconSurfaceRendererCatalog(
        supportedTypes: [
            "Text", "Row", "Column", "Card", "Button", "Metric", "List", "Table",
            "Notice", "Error", "Retry", "Approval", "Receipt"
        ],
        interactiveTypes: ["Button", "Retry", "Approval"]
    )
}
