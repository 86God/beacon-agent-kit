import Foundation
import Testing
@testable import BeaconAgentCore

@Suite
struct BeaconRunBudgetTests {
    @Test
    func heartbeatDoesNotExtendSemanticDeadline() {
        var budget = BeaconRunBudget(startedAt: 0)
        budget.recordConnected(at: 0)
        for second in 1...30 {
            budget.recordHeartbeat(at: TimeInterval(second))
        }
        #expect(budget.decision(at: 15) == .showWaiting)
        #expect(budget.decision(at: 30) == .semanticTimeout)
    }

    @Test
    func resumeResetsSegmentButNotAbsoluteDeadline() {
        var budget = BeaconRunBudget(startedAt: 0)
        budget.recordConnected(at: 0)
        budget.resume(at: 25)
        budget.recordConnected(at: 26)
        #expect(budget.decision(at: 50) == .showWaiting)
        #expect(budget.decision(at: 90) == .totalTimeout)
    }

    @Test
    func toolAndConnectionHaveDistinctDeadlines() {
        let policy = BeaconRunBudgetPolicy(connectSeconds: 10, toolSeconds: 5)
        let connecting = BeaconRunBudget(startedAt: 0, policy: policy)
        #expect(connecting.decision(at: 10) == .connectionTimeout)

        var tool = BeaconRunBudget(startedAt: 0, policy: policy)
        tool.recordConnected(at: 0)
        tool.startTool(at: 1)
        #expect(tool.decision(at: 6) == .toolTimeout)
    }

    @Test
    func retryAndFallbackShareOriginalDeadlineAndCount() {
        var budget = BeaconRunBudget(startedAt: 0)
        let firstRetry = budget.claimTransportRetry(at: 1)
        let secondRetry = budget.claimTransportRetry(at: 2)
        let firstFallback = budget.claimTextFallback(at: 80)
        #expect(firstRetry)
        #expect(!secondRetry)
        #expect(firstFallback)
        #expect(budget.fallbackDeadline(at: 80) == 90)
        let secondFallback = budget.claimTextFallback(at: 81)
        let expiredRetry = budget.claimTransportRetry(at: 90)
        #expect(!secondFallback)
        #expect(!expiredRetry)
    }

    @Test
    func cancellationRejectsLateProgressAndApprovalExpires() {
        var approval = BeaconRunBudget(startedAt: 0)
        approval.waitForApproval(expiresAt: 20)
        #expect(approval.decision(at: 19) == .continue)
        #expect(approval.decision(at: 20) == .approvalExpired)

        var cancelled = BeaconRunBudget(startedAt: 0)
        cancelled.cancel()
        cancelled.recordSemanticProgress(at: 5)
        #expect(cancelled.decision(at: 5) == .cancelled)
    }

    @Test
    func kindDefaultsAndSemanticClassificationMatchContract() {
        #expect(BeaconRunBudgetPolicy.defaults(for: .chat).totalSeconds == 90)
        #expect(BeaconRunBudgetPolicy.defaults(for: .draft).totalSeconds == 120)
        #expect(BeaconRunBudgetPolicy.defaults(for: .image).toolSeconds == 45)
        #expect(!BeaconRunBudget.isSemanticEvent(type: "heartbeat"))
        #expect(!BeaconRunBudget.isSemanticEvent(type: "text.delta", payload: ["delta": .string("")]))
        #expect(BeaconRunBudget.isSemanticEvent(type: "tool.start"))
        #expect(BeaconRunBudget.isSemanticEvent(type: "tool.result"))
        #expect(BeaconRunBudget.isSemanticEvent(type: "tool.end"))
        #expect(BeaconRunBudget.isSemanticEvent(type: "tool.started"))
        #expect(BeaconRunBudget.isSemanticEvent(type: "text.delta", payload: ["delta": .string("完成")]))
    }
}
