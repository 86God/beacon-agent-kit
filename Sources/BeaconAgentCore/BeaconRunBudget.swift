import Foundation

public enum BeaconRunKind: String, Codable, Equatable, Sendable {
    case chat
    case draft
    case image
}

public enum BeaconRunBudgetDecision: String, Codable, Equatable, Sendable {
    case `continue`
    case showWaiting
    case connectionTimeout
    case toolTimeout
    case semanticTimeout
    case totalTimeout
    case approvalExpired
    case cancelled
}

public struct BeaconRunBudgetPolicy: Codable, Equatable, Sendable {
    public let connectSeconds: TimeInterval
    public let toolSeconds: TimeInterval
    public let semanticNoticeSeconds: TimeInterval
    public let semanticTimeoutSeconds: TimeInterval
    public let totalSeconds: TimeInterval
    public let fallbackSeconds: TimeInterval
    public let maxTransportRetries: Int
    public let maxTextFallbacks: Int

    public init(
        connectSeconds: TimeInterval = 10,
        toolSeconds: TimeInterval = 5,
        semanticNoticeSeconds: TimeInterval = 15,
        semanticTimeoutSeconds: TimeInterval = 30,
        totalSeconds: TimeInterval = 90,
        fallbackSeconds: TimeInterval = 15,
        maxTransportRetries: Int = 1,
        maxTextFallbacks: Int = 1
    ) {
        precondition(connectSeconds > 0 && toolSeconds > 0)
        precondition(semanticNoticeSeconds > 0 && semanticNoticeSeconds < semanticTimeoutSeconds)
        precondition(semanticTimeoutSeconds <= totalSeconds && fallbackSeconds > 0)
        precondition(maxTransportRetries >= 0 && maxTextFallbacks >= 0)
        self.connectSeconds = connectSeconds
        self.toolSeconds = toolSeconds
        self.semanticNoticeSeconds = semanticNoticeSeconds
        self.semanticTimeoutSeconds = semanticTimeoutSeconds
        self.totalSeconds = totalSeconds
        self.fallbackSeconds = fallbackSeconds
        self.maxTransportRetries = maxTransportRetries
        self.maxTextFallbacks = maxTextFallbacks
    }

    public static func defaults(for kind: BeaconRunKind) -> Self {
        switch kind {
        case .chat: Self()
        case .draft: Self(totalSeconds: 120)
        case .image: Self(toolSeconds: 45, totalSeconds: 120)
        }
    }
}

public struct BeaconRunBudget: Codable, Equatable, Sendable {
    public let policy: BeaconRunBudgetPolicy
    public let startedAt: TimeInterval
    public let absoluteDeadline: TimeInterval
    public private(set) var segmentStartedAt: TimeInterval
    public private(set) var lastSemanticProgressAt: TimeInterval
    public private(set) var connected: Bool
    public private(set) var toolStartedAt: TimeInterval?
    public private(set) var approvalExpiresAt: TimeInterval?
    public private(set) var transportRetryCount: Int
    public private(set) var textFallbackCount: Int
    public private(set) var isCancelled: Bool
    public private(set) var isTerminal: Bool

    public init(startedAt: TimeInterval, policy: BeaconRunBudgetPolicy = .init()) {
        self.policy = policy
        self.startedAt = startedAt
        absoluteDeadline = startedAt + policy.totalSeconds
        segmentStartedAt = startedAt
        lastSemanticProgressAt = startedAt
        connected = false
        toolStartedAt = nil
        approvalExpiresAt = nil
        transportRetryCount = 0
        textFallbackCount = 0
        isCancelled = false
        isTerminal = false
    }

    public mutating func recordHeartbeat(at _: TimeInterval) {}

    public mutating func recordConnected(at time: TimeInterval) {
        guard !isTerminal else { return }
        connected = true
        recordSemanticProgress(at: time)
    }

    public mutating func recordSemanticProgress(at time: TimeInterval) {
        guard !isTerminal else { return }
        lastSemanticProgressAt = max(lastSemanticProgressAt, time)
    }

    public mutating func startTool(at time: TimeInterval) {
        guard !isTerminal else { return }
        toolStartedAt = time
        recordSemanticProgress(at: time)
    }

    public mutating func finishTool(at time: TimeInterval) {
        guard !isTerminal else { return }
        toolStartedAt = nil
        recordSemanticProgress(at: time)
    }

    public mutating func resume(at time: TimeInterval) {
        guard !isTerminal else { return }
        segmentStartedAt = time
        lastSemanticProgressAt = time
        connected = false
        toolStartedAt = nil
        approvalExpiresAt = nil
    }

    public mutating func waitForApproval(expiresAt: TimeInterval) {
        guard !isTerminal else { return }
        approvalExpiresAt = expiresAt
        toolStartedAt = nil
    }

    public mutating func cancel() {
        isCancelled = true
        isTerminal = true
    }

    public mutating func finish() {
        isTerminal = true
    }

    public mutating func claimTransportRetry(at time: TimeInterval) -> Bool {
        guard !isTerminal,
              time < absoluteDeadline,
              transportRetryCount < policy.maxTransportRetries else { return false }
        transportRetryCount += 1
        return true
    }

    public mutating func claimTextFallback(at time: TimeInterval) -> Bool {
        guard !isTerminal,
              time < absoluteDeadline,
              textFallbackCount < policy.maxTextFallbacks else { return false }
        textFallbackCount += 1
        return true
    }

    public func remainingSeconds(at time: TimeInterval) -> TimeInterval {
        max(0, absoluteDeadline - time)
    }

    public func fallbackDeadline(at time: TimeInterval) -> TimeInterval {
        min(absoluteDeadline, time + policy.fallbackSeconds)
    }

    public func decision(at time: TimeInterval) -> BeaconRunBudgetDecision {
        if isCancelled { return .cancelled }
        if isTerminal { return .continue }
        if time >= absoluteDeadline { return .totalTimeout }
        if let approvalExpiresAt {
            return time >= approvalExpiresAt ? .approvalExpired : .continue
        }
        if let toolStartedAt {
            if time - toolStartedAt >= policy.toolSeconds { return .toolTimeout }
        } else if !connected, time - segmentStartedAt >= policy.connectSeconds {
            return .connectionTimeout
        }
        let semanticElapsed = time - lastSemanticProgressAt
        if semanticElapsed >= policy.semanticTimeoutSeconds { return .semanticTimeout }
        if semanticElapsed >= policy.semanticNoticeSeconds { return .showWaiting }
        return .continue
    }

    public static func isSemanticEvent(type: String, payload: [String: BeaconJSONValue] = [:]) -> Bool {
        if ["heartbeat", "ping", "transport.heartbeat"].contains(type) { return false }
        if type == "text.delta" {
            guard case let .string(delta)? = payload["delta"] else { return false }
            return !delta.isEmpty
        }
        return [
            "run.started", "step.started", "step.finished",
            "tool.start", "tool.result", "tool.end", "tool.started", "tool.finished",
            "run.interrupted", "run.finished", "run.error", "permission.denied",
            "a2ui.patch", "a2ui.snapshot", "state.delta"
        ].contains(type)
    }
}
