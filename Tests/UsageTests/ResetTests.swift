import Foundation
import Testing

@testable import UsageApp
@testable import UsageCore
@testable import UsageProviders

func resetFixture(
    remaining: Double = 6, count: Int? = 3, account: String = "fixture",
    checked: Date = Date(), current: Bool = true, checking: Bool = false,
    configuration: String = "test"
) -> ResetContext {
    let meter = Allowance(
        id: "codex:10080", label: "Weekly", used: 100 - remaining,
        resetsAt: Date().addingTimeInterval(3600), weekly: true, isMain: true)
    return ResetContext(
        snapshot: UsageSnapshot(
            provider: .codex, accountKey: account, allowances: [meter],
            checkedAt: checked, resetCredits: count,
            resetDetails: [
                ResetCredit(id: "sample", title: "Full reset", expiresAt: Date().addingTimeInterval(86400))
            ], accountLabel: "example@example.invalid"), meter: meter, current: current, checking: checking,
        options: .init(), configuration: configuration)
}

struct ResetModelTests {
    @Test func reservesAreAuthoritativeAndDetailsCanBePartial() throws {
        var payload: [String: Any] = [
            "rateLimits": ["primary": ["usedPercent": 94, "windowDurationMins": 10080]],
            "rateLimitResetCredits": [
                "availableCount": 5,
                "credits": [
                    [
                        "id": "a", "status": "available", "resetType": "codexRateLimits",
                        "title": "Full reset", "expiresAt": 1_900_000_000,
                    ],
                    ["id": "a", "status": "available", "resetType": "codexRateLimits"],
                    ["id": "used", "status": "redeemed", "resetType": "codexRateLimits"],
                ],
            ],
        ]
        let snapshot = try Normalize.codex(payload, identity: "fixture")
        #expect(snapshot.resetCredits == 5)
        #expect(snapshot.resetDetails.count == 1)
        #expect(snapshot.resetDetails.first?.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
        for invalid in [true, -1, 3.5, 100_000] as [Any] {
            payload["rateLimitResetCredits"] = ["availableCount": invalid]
            #expect(try Normalize.codex(payload, identity: "fixture").resetCredits == nil)
        }
        payload["rateLimitResetCredits"] = ["availableCount": 0, "credits": NSNull()]
        #expect(try Normalize.codex(payload, identity: "fixture").resetCredits == 0)
    }
    @Test func promptRequiresFreshLowAllowanceAndARealReserve() {
        #expect(resetFixture().eligible())
        #expect(resetFixture(remaining: 10).eligible())
        #expect(!resetFixture(remaining: 10.1).eligible())
        #expect(!resetFixture(count: 0).eligible())
        #expect(!resetFixture(count: nil).eligible())
        #expect(!resetFixture(current: false).eligible())
        #expect(!resetFixture(checking: true).eligible())
        #expect(!resetFixture(checked: Date().addingTimeInterval(-901)).eligible())
    }
    @Test func stripKeepsAvailableLeftAndUsedRightWithoutInventingCapacity() {
        let before = SpareSlots(available: 3, used: 2)
        let after = SpareSlots(available: 2, used: 3)
        #expect(before.total == after.total)
        #expect(before.filled - 1 == after.filled)
        #expect(SpareSlots(available: 0, used: 0).total == 1)
        #expect(SpareSlots(available: 0, used: 5).empty == 5)
        #expect(SpareSlots(available: 100, used: 23).total == 6)
        #expect(SpareSlots(available: 100, used: 23).abbreviated)
    }
    @Test func accountHistorySurvivesPlanChangeButNotAnotherAccount() throws {
        func account(_ email: String, _ plan: String) -> [String: Any] {
            ["account": ["type": "chatgpt", "email": email, "planType": plan]]
        }
        #expect(
            try Normalize.codexIdentity(account("a", "plus")) == Normalize.codexIdentity(account("a", "pro")))
        #expect(
            try Normalize.codexIdentity(account("a", "pro")) != Normalize.codexIdentity(account("b", "pro")))
    }
}

@MainActor struct ResetControllerTests {
    func ledger() throws -> ResetLedger {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sparebar-resets-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return ResetLedger(directory: path)
    }
    func settled(_ controller: ResetController) async throws {
        for _ in 0..<100 where controller.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.busy)
    }
    @Test func uncertainRequestSurvivesRestartAndRetryDoesNotMintAnotherKey() async throws {
        let ledger = try ledger()
        defer { try? FileManager.default.removeItem(at: ledger.directory) }
        let first = ResetController(
            ledger: ledger,
            consume: { attempt, _, _ in
                #expect((try? ledger.record(for: "fixture"))?.pending == attempt)
                return .uncertain(.timeout)
            })
        first.update(resetFixture())
        first.ask()
        first.confirm()
        first.confirm()
        try await settled(first)
        let pending = try #require(ledger.record(for: "fixture").pending)
        #expect(!first.canOffer)
        let reopened = ResetController(
            ledger: ledger,
            consume: { attempt, _, retry in
                #expect(retry)
                #expect(attempt.id == pending.id)
                return .completed(.alreadyRedeemed)
            })
        reopened.update(resetFixture(remaining: 80, count: 2))
        #expect(reopened.canRetry)
        reopened.ask(retry: true)
        reopened.confirm()
        try await settled(reopened)
        #expect(try ledger.record(for: "fixture").pending == nil)
        #expect(try ledger.record(for: "fixture").receipts.count == 1)
        #expect(reopened.context?.snapshot.preferred?.remaining == 80)
        #expect(reopened.context?.snapshot.resetCredits == 2)
    }
    @Test func retryPreflightFailureKeepsTheUnresolvedKey() async throws {
        let ledger = try ledger()
        defer { try? FileManager.default.removeItem(at: ledger.directory) }
        let attempt = ResetAttempt(accountKey: "fixture", meterID: "codex:10080")
        try ledger.begin(attempt)
        let controller = ResetController(ledger: ledger, consume: { _, _, _ in .notSent(.accountChanged) })
        controller.update(resetFixture())
        controller.ask(retry: true)
        controller.confirm()
        try await settled(controller)
        #expect(try ledger.record(for: "fixture").pending == attempt)
        #expect(!controller.canOffer)
    }
    @Test(arguments: [ResetDisposition.reset, .alreadyRedeemed, .noCredit, .nothingToReset])
    func onlyConfirmedConsumptionCounts(outcome: ResetDisposition) async throws {
        let ledger = try ledger()
        defer { try? FileManager.default.removeItem(at: ledger.directory) }
        let controller = ResetController(ledger: ledger, consume: { _, _, _ in .completed(outcome) })
        controller.update(resetFixture())
        controller.ask()
        controller.confirm()
        try await settled(controller)
        #expect(controller.record.receipts.count == (outcome.redeemed ? 1 : 0))
        controller.update(resetFixture(count: 1))
        #expect(controller.record.receipts.count == (outcome.redeemed ? 1 : 0))
        controller.update(resetFixture(account: "other"))
        #expect(controller.record.receipts.isEmpty)
        #expect(controller.record.pending == nil)
    }
    @Test func accountOrConfigurationChangeCancelsConfirmationAndCancelNeverConsumes() throws {
        let ledger = try ledger()
        defer { try? FileManager.default.removeItem(at: ledger.directory) }
        let controller = ResetController(
            ledger: ledger,
            consume: { _, _, _ in
                Issue.record("Unexpected reset request")
                return .completed(.reset)
            })
        controller.update(resetFixture())
        controller.ask()
        controller.cancelConfirmation()
        controller.confirm()
        controller.ask()
        controller.update(resetFixture(account: "other"))
        controller.confirm()
        #expect(controller.confirmation == nil)
        controller.ask()
        controller.update(resetFixture(account: "other", configuration: "new"))
        controller.confirm()
        #expect(controller.confirmation == nil)
        #expect(try ledger.record(for: "fixture").pending == nil)
        #expect(try ledger.record(for: "other").pending == nil)
    }
    @Test(arguments: [false, true], [false, true])
    func inFlightResultsStayWithTheirAccountAndConfiguration(otherAccount: Bool, unsupported: Bool)
        async throws
    {
        let ledger = try ledger()
        defer { try? FileManager.default.removeItem(at: ledger.directory) }
        let controller = ResetController(
            ledger: ledger,
            consume: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(50))
                return unsupported ? .notSent(.unsupported) : .completed(.reset)
            })
        controller.update(resetFixture())
        controller.ask()
        controller.confirm()
        #expect(controller.busyInCurrentContext)
        controller.update(resetFixture(account: otherAccount ? "other" : "fixture", configuration: "new"))
        #expect(controller.busy)
        #expect(!controller.busyInCurrentContext)
        #expect(!controller.canOffer)
        try await settled(controller)
        #expect(!controller.unsupported)
        #expect(!controller.awaitingRefresh)
        #expect(controller.message == nil)
        #expect(try ledger.record(for: "fixture").receipts.count == (unsupported ? 0 : 1))
        #expect(try ledger.record(for: "other").receipts.isEmpty == true)
    }
    @Test func corruptHistoryFailsClosedAndConcurrentNewRequestIsRejected() throws {
        let ledger = try ledger()
        defer { try? FileManager.default.removeItem(at: ledger.directory) }
        try ledger.begin(ResetAttempt(accountKey: "fixture", meterID: "weekly"))
        #expect(throws: ResetLedger.Failure.pendingRequest) {
            try ledger.begin(ResetAttempt(accountKey: "fixture", meterID: "weekly"))
        }
        try Data("invalid".utf8).write(to: ledger.directory.appendingPathComponent("ledger.json"))
        let controller = ResetController(ledger: ledger)
        controller.update(resetFixture())
        #expect(!controller.canOffer)
        #expect(!controller.storageReady)
    }
}
