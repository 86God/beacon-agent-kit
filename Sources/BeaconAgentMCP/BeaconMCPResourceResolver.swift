import Foundation

public struct BeaconMCPResourceResolver: Sendable {
    public let maximumBytes: Int

    public init(maximumBytes: Int = 262_144) {
        self.maximumBytes = maximumBytes
    }

    public func resolve(
        requestedURI: String,
        from resources: [BeaconMCPResource]
    ) throws -> BeaconMCPResource {
        guard requestedURI.hasPrefix("ui://"), URL(string: requestedURI) != nil else {
            throw BeaconMCPResourceError.invalidURI(requestedURI)
        }
        guard let resource = resources.first(where: { $0.uri == requestedURI }) else {
            throw BeaconMCPResourceError.notFound(requestedURI)
        }
        guard resource.mimeType.lowercased() == "text/html;profile=mcp-app" else {
            throw BeaconMCPResourceError.invalidMIMEType(resource.mimeType)
        }
        let byteCount = resource.text?.utf8.count ?? resource.blob?.count ?? 0
        guard byteCount <= maximumBytes else {
            throw BeaconMCPResourceError.oversized(requestedURI)
        }
        return resource
    }
}
