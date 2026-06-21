import Foundation
import BeaconAgentCore

public enum BeaconAGUIEventAdapter {
    public static func events(from data: Data) throws -> [BeaconAgentEvent] {
        try BeaconAGUIEventDecoder.decodeLines(data)
    }
}
