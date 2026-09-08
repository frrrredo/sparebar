import Foundation
import Testing
import UsageCore
@testable import UsageApp
@testable import UsageProviders

private func statusSnapshot(_ status: String, incident: String? = nil) -> ServiceHealthSnapshot {
    .init(
        components: [
            .init(id: "chat", name: "ChatGPT", status: "operational"),
            .init(id: "images", name: "Images", status: status),
            .init(id: "code", name: "Codex", status: "operational"),
        ],
        incidents: incident.map { [.init(id: $0, name: "Sample image incident", status: "investigating", impact: "major")] } ?? [])
}

struct ServiceHealthTests {
    private let start = Date(timeIntervalSince1970: 10_000)

    @Test func partialReportsPreserveComponentScopeAndUnrecognizedValuesAreUnknown() throws {
        let data = Data(#"{"components":[{"id":"chat","name":"ChatGPT","status":"operational"},{"id":"images","name":"Images","status":"degraded_performance"},{"id":"code","name":"Codex","status":"operational"}],"incidents":[],"status":{"indicator":"minor"}}"#.utf8)
        let snapshot = try ServiceHealthSnapshot(data: data)
        #expect(snapshot.level == .degraded)
        #expect(snapshot.affected.map(\.name) == ["Images"])
        #expect(snapshot.components.last?.level == .operational)
        #expect(statusSnapshot("future_status").level == .unknown)
        #expect(statusSnapshot("under_maintenance").level == .degraded)
        #expect(ServiceHealthSnapshot(components: [], indicator: "none").level == .unknown)
        #expect(throws: (any Error).self) { try ServiceHealthSnapshot(data: Data(#"{"status":{"indicator":"none"}}"#.utf8)) }
        #expect(throws: (any Error).self) {
            try ServiceHealthSnapshot(data: Data(#"{"components":[{"id":"same","name":"A","status":"operational"},{"id":"same","name":"B","status":"operational"}],"incidents":[]}"#.utf8))
        }
    }

    @Test func activeIncidentsOverrideOperationalComponentsAndResolvedIncidentsDoNot() {
        #expect(statusSnapshot("operational", incident: "incident-1").level == .outage)
        let resolved = ServiceIncident(id: "old", name: "Old issue", status: "resolved", impact: "critical")
        let snapshot = ServiceHealthSnapshot(components: statusSnapshot("operational").components, incidents: [resolved])
        #expect(snapshot.level == .operational)
        #expect(snapshot.incidents.isEmpty)
    }

    @Test func failuresAndAgedResultsNeverAnnounceAnOutage() {
        var state = ServiceHealthState()
        #expect(state.level(at: start) == .unknown)
        state.apply(statusSnapshot("operational"), at: start)
        #expect(state.signal == nil)
        state.fail()
        #expect(state.level(at: start) == .unknown)
        #expect(state.snapshot?.level == .operational)
        state.apply(statusSnapshot("operational"), at: start)
        #expect(state.level(at: start.addingTimeInterval(601)) == .unknown)
        #expect(state.signal == nil)
    }

    @Test func remindersWaitTenMinutesAndAcknowledgmentSurvivesUnchangedPolls() {
        var state = ServiceHealthState()
        let outage = statusSnapshot("major_outage", incident: "one")
        state.apply(outage, at: start)
        #expect(state.signal?.kind == .alert)
        let sequence = state.signal?.sequence
        state.apply(outage, at: start.addingTimeInterval(300))
        #expect(state.signal?.sequence == sequence)
        let early = state.remind(at: start.addingTimeInterval(599))
        let due = state.remind(at: start.addingTimeInterval(600))
        let repeated = state.remind(at: start.addingTimeInterval(601))
        #expect(!early)
        #expect(due)
        #expect(!repeated)
        state.acknowledge()
        state.apply(outage, at: start.addingTimeInterval(1200))
        #expect(state.acknowledged)
        let afterAcknowledgment = state.remind(at: start.addingTimeInterval(1201))
        #expect(!afterAcknowledgment)
        state.apply(statusSnapshot("major_outage", incident: "two"), at: start.addingTimeInterval(1202))
        #expect(!state.acknowledged)
        #expect(state.nextReminder == start.addingTimeInterval(1802))
    }

    @Test func degradationAndReadingDoNotScheduleOutageReminders() {
        var state = ServiceHealthState()
        state.apply(statusSnapshot("degraded_performance"), at: start)
        #expect(state.signal?.kind == .alert)
        #expect(state.nextReminder == nil)
        state.apply(statusSnapshot("major_outage"), at: start.addingTimeInterval(1), reading: true)
        #expect(state.acknowledged)
        #expect(state.nextReminder == nil)
    }

    @Test func unknownReportsPauseRemindersWithoutDiscardingAcknowledgment() {
        var state = ServiceHealthState()
        let outage = statusSnapshot("major_outage")
        state.apply(outage, at: start)
        state.apply(statusSnapshot("future_status"), at: start.addingTimeInterval(300))
        let paused = state.remind(at: start.addingTimeInterval(600))
        #expect(!paused)
        state.apply(outage, at: start.addingTimeInterval(601))
        let resumed = state.remind(at: start.addingTimeInterval(602))
        #expect(resumed)
        state.acknowledge()
        state.apply(statusSnapshot("future_status"), at: start.addingTimeInterval(900))
        state.apply(outage, at: start.addingTimeInterval(1200))
        #expect(state.acknowledged)
        let suppressed = state.remind(at: start.addingTimeInterval(1201))
        #expect(!suppressed)
    }

    @Test func recoveryIsOneTransitionAndStaleOrUnknownDataCannotTriggerIt() {
        var state = ServiceHealthState()
        state.apply(statusSnapshot("major_outage"), at: start)
        state.fail()
        let afterFailure = state.remind(at: start.addingTimeInterval(601))
        #expect(!afterFailure)
        state.apply(statusSnapshot("new_unrecognized_status"), at: start.addingTimeInterval(602))
        #expect(state.signal == nil)
        state.apply(statusSnapshot("operational"), at: start.addingTimeInterval(603))
        #expect(state.signal?.kind == .recovery)
        let sequence = state.signal?.sequence
        state.apply(statusSnapshot("operational"), at: start.addingTimeInterval(903))
        #expect(state.signal?.sequence == sequence)
        #expect(state.nextReminder == nil)
    }

    @Test func retryBackoffAndServerDelayAreRespected() {
        var state = ServiceHealthState()
        state.fail()
        #expect(state.retryDelay() == 600)
        state.fail()
        #expect(state.retryDelay() == 1200)
        #expect(state.retryDelay(serverDelay: 7200) == 7200)
        for _ in 0..<20 { state.fail() }
        #expect(state.retryDelay() == 3600)
        #expect(ServiceHealthClient.retryAfter("120") == 120)
        #expect(ServiceHealthClient.retryAfter("invalid") == nil)
        #expect(ServiceHealthClient.retryAfter("NaN") == nil)
        #expect(ServiceHealthClient.retryAfter("1e300") == 31_536_000)
        #expect(ServiceHealthClient.retryAfter("Thu, 01 Jan 1970 00:03:00 GMT", now: Date(timeIntervalSince1970: 0)) == 180)
    }
}

private actor PendingStatusReads {
    var calls: [Provider: Int] = [:]
    var cancellations = 0
    func read(_ provider: Provider) async throws -> ServiceHealthSnapshot {
        calls[provider, default: 0] += 1
        do { try await Task.sleep(for: .seconds(3600)) }
        catch { cancellations += 1; throw error }
        return statusSnapshot("operational")
    }
    var total: Int { calls.values.reduce(0, +) }
}

@MainActor struct ServiceHealthLifecycleTests {
    @Test func sleepDisableAndShutdownCancelRequestsAndWakeStartsOnePerProvider() async throws {
        let reads = PendingStatusReads()
        let controller = ServiceHealthController(demo: false, read: { try await reads.read($0) }, jitter: { 0 })
        controller.start(providers: [.codex, .claude])
        for _ in 0..<100 where await reads.total < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await reads.total == 2)
        controller.setProviders([.codex, .claude])
        #expect(await reads.total == 2)
        controller.sleep()
        for _ in 0..<100 where await reads.cancellations < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await reads.cancellations == 2)
        controller.wake()
        for _ in 0..<100 where await reads.total < 4 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await reads.total == 4)
        controller.setProviders([.codex])
        await controller.shutdown()
        #expect(await reads.cancellations == 4)
        #expect(controller.states.values.allSatisfy { $0.snapshot == nil })
    }

    @Test func demoNeverReadsPublicFeedsAndRecoveryUsesTheSameStateMachine() async {
        let reads = PendingStatusReads()
        let controller = ServiceHealthController(demo: true, read: { try await reads.read($0) })
        controller.start(providers: [.claude])
        controller.showDemo(.claude, level: .outage)
        controller.reading = true
        #expect(controller.states[.claude]?.acknowledged == true)
        controller.showDemo(.claude, level: .operational)
        #expect(controller.states[.claude]?.signal?.kind == .recovery)
        await controller.shutdown()
        #expect(await reads.total == 0)
    }

    @Test func eachProviderSignalPlaysOnceEvenWhenRotationDelaysItsPresentation() async {
        let controller = ServiceHealthController(demo: true)
        controller.showDemo(.claude, level: .outage)
        let first = controller.consumeSignal(.claude, at: Date().addingTimeInterval(10))
        let duplicate = controller.consumeSignal(.claude)
        #expect(first)
        #expect(!duplicate)
        controller.showDemo(.codex, level: .outage)
        #expect(controller.consumeSignal(.codex))
        controller.showDemo(.claude, level: .operational)
        #expect(controller.consumeSignal(.claude))
        controller.showDemo(.claude, level: .outage)
        #expect(!controller.consumeSignal(.claude, at: Date().addingTimeInterval(70)))
        await controller.shutdown()
    }
}
