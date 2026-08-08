import Foundation
import BeaconAgentCore

public enum BeaconA2UISurfaceStatus: String, Codable, Equatable, Sendable {
    case streaming
    case complete
    case error
}

public struct BeaconA2UIAction: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let payload: [String: BeaconJSONValue]

    public init(id: String, name: String, payload: [String: BeaconJSONValue]) {
        self.id = id
        self.name = name
        self.payload = payload
    }
}

public struct BeaconA2UIComponent: Codable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let properties: [String: BeaconJSONValue]
    public let children: [String]
    public let actions: [BeaconA2UIAction]

    public init(
        id: String,
        type: String,
        properties: [String: BeaconJSONValue] = [:],
        children: [String] = [],
        actions: [BeaconA2UIAction] = []
    ) {
        self.id = id
        self.type = type
        self.properties = properties
        self.children = children
        self.actions = actions
    }

    func replacing(children: [String]) -> BeaconA2UIComponent {
        BeaconA2UIComponent(
            id: id,
            type: type,
            properties: properties,
            children: children,
            actions: actions
        )
    }
}

public struct BeaconA2UISurface: Codable, Equatable, Sendable {
    public var id: String
    public var revision: Int
    public var rootComponentID: String
    public var components: [String: BeaconA2UIComponent]
    public var status: BeaconA2UISurfaceStatus

    public init(
        id: String,
        revision: Int,
        rootComponentID: String,
        components: [String: BeaconA2UIComponent],
        status: BeaconA2UISurfaceStatus
    ) {
        self.id = id
        self.revision = revision
        self.rootComponentID = rootComponentID
        self.components = components
        self.status = status
    }
}

public enum BeaconA2UIPatchOperation: Equatable, Sendable {
    case upsert(BeaconA2UIComponent)
    case remove(componentID: String)
    case setChildren(componentID: String, children: [String])
    case setRoot(componentID: String)
}
