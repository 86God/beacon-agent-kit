import Foundation

public struct BeaconSSEMessage: Equatable, Sendable {
    public let data: String
    public let id: String?
    public let retryMilliseconds: Int?

    public init(data: String, id: String?, retryMilliseconds: Int?) {
        self.data = data
        self.id = id
        self.retryMilliseconds = retryMilliseconds
    }
}

public enum BeaconAGUISSEParserError: Error, Equatable, Sendable {
    case invalidUTF8
}

/// Incremental SSE parser that waits for complete UTF-8 lines before decoding them.
public struct BeaconAGUISSEParser: Sendable {
    private var buffer = Data()
    private var dataLines: [String] = []
    private var eventID: String?
    private var retryMilliseconds: Int?

    public init() {}

    public mutating func append(_ chunk: Data) throws -> [BeaconSSEMessage] {
        buffer.append(chunk)
        var messages: [BeaconSSEMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            messages.append(contentsOf: try process(line))
        }
        return messages
    }

    public mutating func finish() throws -> [BeaconSSEMessage] {
        var messages: [BeaconSSEMessage] = []
        if !buffer.isEmpty {
            var line = buffer
            buffer.removeAll(keepingCapacity: false)
            if line.last == 0x0D {
                line.removeLast()
            }
            messages.append(contentsOf: try process(line))
        }
        if let message = dispatchPending() {
            messages.append(message)
        }
        return messages
    }

    private mutating func process(_ lineData: Data) throws -> [BeaconSSEMessage] {
        guard let line = String(data: lineData, encoding: .utf8) else {
            throw BeaconAGUISSEParserError.invalidUTF8
        }
        if line.isEmpty {
            return dispatchPending().map { [$0] } ?? []
        }
        if line.hasPrefix(":") {
            return []
        }
        let field: String
        var value: String
        if let separator = line.firstIndex(of: ":") {
            field = String(line[..<separator])
            value = String(line[line.index(after: separator)...])
            if value.first == " " {
                value.removeFirst()
            }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "data":
            dataLines.append(value)
        case "id" where !value.contains("\0"):
            eventID = value
        case "retry":
            retryMilliseconds = Int(value)
        default:
            break
        }
        return []
    }

    private mutating func dispatchPending() -> BeaconSSEMessage? {
        guard !dataLines.isEmpty else {
            eventID = nil
            retryMilliseconds = nil
            return nil
        }
        let message = BeaconSSEMessage(
            data: dataLines.joined(separator: "\n"),
            id: eventID,
            retryMilliseconds: retryMilliseconds
        )
        dataLines.removeAll(keepingCapacity: true)
        eventID = nil
        retryMilliseconds = nil
        return message
    }
}
