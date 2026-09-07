import Darwin
import Foundation
import Testing

@testable import UsageCore
@testable import UsageProviders

struct UsageTests {
    func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    @Test func codexWeeklyPrimaryAndUnixSeconds() throws {
        let payload = try json(
            #"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1900000000}},"extra":{"limitName":"Example model","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1900000001}}},"rateLimitResetCredits":{"availableCount":3}}"#
        )
        let snapshot = try Normalize.codex(payload, identity: "synthetic")
        #expect(snapshot.preferred?.weekly == true)
        #expect(snapshot.preferred?.remaining == 88)
        #expect(snapshot.preferred?.resetsAt?.timeIntervalSince1970 == 1_900_000_000)
        #expect(snapshot.allowances.count == 2)
        #expect(snapshot.resetCredits == 3)
    }
    @Test func codexFallbackAndRejectsBooleanPercent() throws {
        let snapshot = try Normalize.codex(
            json(#"{"rateLimits":{"primary":{"usedPercent":0.5,"windowDurationMins":300}}}"#),
            identity: "synthetic")
        #expect(snapshot.preferred?.remaining == 99.5)
        #expect(throws: UsageIssue.unavailable) {
            try Normalize.codex(
                json(#"{"rateLimits":{"primary":{"usedPercent":true,"windowDurationMins":300}}}"#),
                identity: "synthetic")
        }
        #expect(throws: UsageIssue.unavailable) {
            try Normalize.codex(
                json(#"{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":1e100}}}"#),
                identity: "synthetic")
        }
    }
    @Test func claudeScopedInactiveLimitAndNullReset() throws {
        let payload = try json(
            #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":4,"resets_at":"2030-01-01T12:00:00.123+00:00"},"seven_day":{"utilization":0,"resets_at":null},"unrelated":{"utilization":99},"limits":[{"kind":"weekly_all","percent":0,"resets_at":null,"is_active":false},{"kind":"weekly_scoped","percent":32,"resets_at":"2030-01-01T12:00:00Z","is_active":false,"scope":{"model":{"id":null,"display_name":"Example model"}}}]}}"#
        )
        let snapshot = try Normalize.claude(payload, identity: "synthetic")
        #expect(snapshot.allowances.count == 3)
        #expect(snapshot.preferred?.remaining == 100)
        #expect(snapshot.preferred?.resetsAt == nil)
        let scoped = try #require(snapshot.allowances.first { !$0.isMain })
        #expect(scoped.remaining == 68)
        #expect(scoped.label == "Example model / Weekly")
        #expect(scoped.resetsAt != nil)
    }
    @Test func missingIsNeverZero() throws {
        for raw in [
            #"{"rate_limits_available":true,"rate_limits":null}"#,
            #"{"rate_limits":{"seven_day":{"utilization":null}}}"#,
            #"{"rate_limits":{"seven_day":{"utilization":101}}}"#,
        ] {
            #expect(throws: UsageIssue.unavailable) { try Normalize.claude(json(raw), identity: "synthetic") }
        }
    }
    @Test func resetAndSelectionMustNotInventReadings() {
        let now = Date()
        let allowance = Allowance(
            id: "weekly", label: "Weekly", used: 88, resetsAt: now.addingTimeInterval(5), weekly: true,
            isMain: true)
        var state = ProviderState()
        state.apply(
            .success(
                .init(provider: .claude, accountKey: "A", allowances: [allowance], checkedAt: now),
                executable: "/example", version: "1"), at: now)
        #expect(state.isCurrent(allowance, at: now))
        #expect(!state.isCurrent(allowance, at: now.addingTimeInterval(6)))
        #expect(state.snapshot?.preferred?.remaining == 12)
        #expect(state.meter(selected: "model-no-longer-returned") == nil)
    }
    @Test func accountChangeAndFailureRetention() {
        let allowance = Allowance(
            id: "w", label: "Weekly", used: 30, resetsAt: nil, weekly: true, isMain: true)
        var state = ProviderState()
        state.apply(
            .success(
                .init(provider: .claude, accountKey: "A", allowances: [allowance]), executable: "/example",
                version: "1"))
        state.apply(.failure(.timeout, accountKey: "A", executable: "/example"))
        #expect(state.snapshot != nil)
        #expect(!state.isCurrent(allowance))
        state.apply(.failure(.timeout, accountKey: "B", executable: "/example"))
        #expect(state.snapshot == nil)
    }
    @Test func identityChangesWithWorkspace() throws {
        let a = try Normalize.claudeIdentity(
            json(
                #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"example@example.invalid","orgId":"A"}"#
            ))
        let b = try Normalize.claudeIdentity(
            json(
                #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"example@example.invalid","orgId":"B"}"#
            ))
        #expect(a != b)
        #expect(!a.contains("example"))
    }
    @Test func warningThresholdsUseRemaining() {
        #expect(Severity.remaining(20) == .low)
        #expect(Severity.remaining(10) == .critical)
        #expect(Severity.remaining(nil) == .unavailable)
        #expect(Severity.remaining(21) == .normal)
    }
    @Test func explicitMissingExecutableDoesNotFallBack() {
        #expect(CLIDiscovery.resolve(.codex, custom: "/nonexistent/sparebar-test") == nil)
    }
    @Test func failedLaunchDoesNotSignalTheCaller() {
        #expect(throws: UsageIssue.launchFailed) {
            _ = try LineProcess(
                executable: "/definitely-missing-sparebar-test-helper", arguments: [], environment: [:],
                directory: "/tmp")
        }
        #expect(kill(getpid(), 0) == 0)
    }
    @Test func transportDrainsStderrAndHandlesPathsWithSpaces() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sparebar test \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: path) }
        let session = try LineProcess(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=32768 count=4 >&2 2>/dev/null; printf '{\"ok\":true}\\n'"],
            environment: ["PATH": "/usr/bin:/bin"], directory: path.path, timeout: 3)
        defer { session.stop() }
        #expect(try session.json()["ok"] as? Bool == true)
    }
    @Test func transportTimeoutAndOutputBound() throws {
        let slow = try LineProcess(
            executable: "/bin/sleep", arguments: ["10"], environment: [:], directory: "/tmp", timeout: 0.15)
        defer { slow.stop() }
        #expect(throws: UsageIssue.timeout) { try slow.line() }
        let loud = try LineProcess(
            executable: "/usr/bin/yes", arguments: [], environment: [:], directory: "/tmp", timeout: 2,
            maximumOutput: 128)
        defer { loud.stop() }
        #expect(throws: UsageIssue.outputLimit) { while true { _ = try loud.line() } }
    }
    @Test func cancellationReapsOwnedHelper() throws {
        let session = try LineProcess(
            executable: "/bin/sleep", arguments: ["10"], environment: [:], directory: "/tmp")
        let pid = session.processID
        session.requestStop()
        #expect(throws: UsageIssue.cancelled) { try session.line() }
        session.stop()
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
    @Test func cancellationStopsDescendants() throws {
        let session = try LineProcess(
            executable: "/bin/sh", arguments: ["-c", "trap 'wait; exit' TERM; sleep 30 & echo $!; wait"],
            environment: ["PATH": "/bin:/usr/bin"], directory: "/tmp", timeout: 3)
        defer { session.stop() }
        let child = try #require(
            Int32(
                String(decoding: try session.line(), as: UTF8.self).trimmingCharacters(
                    in: .whitespacesAndNewlines)))
        session.stop()
        // stop() reaps the direct child; descendant PIDs can disappear shortly afterward.
        let deadline = Date().addingTimeInterval(2)
        while kill(child, 0) == 0, Date() < deadline { usleep(10_000) }
        #expect(kill(child, 0) == -1)
        #expect(errno == ESRCH)
    }
    @Test func protocolRefusesModelAndBehaviorRequests() throws {
        let session = try LineProcess(
            executable: "/bin/cat", arguments: [], environment: [:], directory: "/tmp", timeout: 2)
        defer { session.stop() }
        #expect(throws: UsageIssue.unexpectedMessage) {
            try ProviderReader.codexRequest(session, id: 1, method: "turn/start", params: [:])
        }
        #expect(throws: UsageIssue.unexpectedMessage) {
            try ProviderReader.claudeRequest(
                session, id: "x", request: ["subtype": "get_usage", "skip_behaviors": false])
        }
    }
}
