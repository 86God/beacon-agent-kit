import Foundation

public enum BeaconA2UIStoreError: Error, Equatable, Sendable {
    case surfaceAlreadyExists(String)
    case surfaceNotFound(String)
    case componentNotFound(String)
    case revisionMismatch(expected: Int, received: Int)
    case revisionGap(expected: Int, received: Int)
    case staleSnapshot(current: Int, received: Int)
}

public struct BeaconA2UIStore: Sendable {
    private var surfaces: [String: BeaconA2UISurface] = [:]
    private let validator: BeaconA2UIValidator

    public init(validator: BeaconA2UIValidator = BeaconA2UIValidator()) {
        self.validator = validator
    }

    public func surface(id: String) -> BeaconA2UISurface? {
        surfaces[id]
    }

    public mutating func create(_ surface: BeaconA2UISurface) throws {
        guard surfaces[surface.id] == nil else {
            throw BeaconA2UIStoreError.surfaceAlreadyExists(surface.id)
        }
        try validator.validate(surface)
        surfaces[surface.id] = surface
    }

    public mutating func update(
        surfaceID: String,
        component: BeaconA2UIComponent,
        revision: Int
    ) throws {
        guard var candidate = surfaces[surfaceID] else {
            throw BeaconA2UIStoreError.surfaceNotFound(surfaceID)
        }
        try requireNextRevision(current: candidate.revision, received: revision)
        candidate.components[component.id] = component
        candidate.revision = revision
        try validator.validate(candidate)
        surfaces[surfaceID] = candidate
    }

    public mutating func patch(
        surfaceID: String,
        baseRevision: Int,
        revision: Int,
        operations: [BeaconA2UIPatchOperation]
    ) throws {
        guard var candidate = surfaces[surfaceID] else {
            throw BeaconA2UIStoreError.surfaceNotFound(surfaceID)
        }
        guard baseRevision == candidate.revision else {
            throw BeaconA2UIStoreError.revisionMismatch(
                expected: candidate.revision,
                received: baseRevision
            )
        }
        try requireNextRevision(current: candidate.revision, received: revision)
        for operation in operations {
            switch operation {
            case let .upsert(component):
                candidate.components[component.id] = component
            case let .remove(componentID):
                candidate.components.removeValue(forKey: componentID)
            case let .setChildren(componentID, children):
                guard let component = candidate.components[componentID] else {
                    throw BeaconA2UIStoreError.componentNotFound(componentID)
                }
                candidate.components[componentID] = component.replacing(children: children)
            case let .setRoot(componentID):
                candidate.rootComponentID = componentID
            }
        }
        candidate.revision = revision
        try validator.validate(candidate)
        surfaces[surfaceID] = candidate
    }

    public mutating func complete(surfaceID: String, revision: Int) throws {
        guard var candidate = surfaces[surfaceID] else {
            throw BeaconA2UIStoreError.surfaceNotFound(surfaceID)
        }
        try requireNextRevision(current: candidate.revision, received: revision)
        candidate.revision = revision
        candidate.status = .complete
        try validator.validate(candidate)
        surfaces[surfaceID] = candidate
    }

    public mutating func applySnapshot(_ snapshot: BeaconA2UISurface) throws {
        if let current = surfaces[snapshot.id], snapshot.revision < current.revision {
            throw BeaconA2UIStoreError.staleSnapshot(
                current: current.revision,
                received: snapshot.revision
            )
        }
        try validator.validate(snapshot)
        surfaces[snapshot.id] = snapshot
    }

    private func requireNextRevision(current: Int, received: Int) throws {
        let expected = current + 1
        guard received == expected else {
            throw BeaconA2UIStoreError.revisionGap(expected: expected, received: received)
        }
    }
}
