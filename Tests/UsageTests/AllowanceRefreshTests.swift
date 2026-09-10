import Foundation
import Testing
import UsageCore

@testable import UsageApp

private actor AllowanceRefreshProbe {
    private(set) var reads: [Provider: Int] = [:]
    private(set) var waits = 0
    var held: Bool

    init(held: Bool = false) { self.held = held }

    func read(_ provider: Provider) async -> ReadOutcome {
        reads[provider, default: 0] += 1
        while held {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return .failure(.cancelled, accountKey: nil, executable: "Fixture") }
        }
        return .success(
            .init(provider: provider, accountKey: "fixture", allowances: [
                .init(id: "weekly", label: "Weekly", used: 25, resetsAt: nil, weekly: true, isMain: true)
            ]), executable: "Fixture", version: "Test")
    }

    func pause(_ duration: TimeInterval) async throws {
        waits += 1
        // Return before the real deadline once; subsequent timers stay pending.
        if waits == 1 { return }
        try await Task.sleep(for: .seconds(3600))
    }

    func release() { held = false }
    var total: Int { reads.values.reduce(0, +) }
}

@MainActor struct AllowanceRefreshTests {
    private func store(_ probe: AllowanceRefreshProbe, claude: Bool = true) throws -> (UsageStore, () -> Void) {
        let suite = "SparebarTests.Refresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "enabled.codex")
        defaults.set(claude, forKey: "enabled.claude")
        defaults.set(false, forKey: "rotation")
        // Keep service health synthetic while exercising real allowance scheduling.
        let store = UsageStore(
            demo: true, defaults: defaults, read: { provider, _ in await probe.read(provider) },
            pause: { try await probe.pause($0) })
        store.demo = false
        return (store, { defaults.removePersistentDomain(forName: suite) })
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await predicate(), "Expected asynchronous refresh state was not reached")
    }

    @Test func earlyTimerWakeRearmsWithoutStartingAnotherRead() async throws {
        let probe = AllowanceRefreshProbe()
        let (store, cleanup) = try store(probe, claude: false)
        defer { cleanup() }
        store.refreshAll()
        try await eventually { await probe.waits >= 2 }
        #expect(await probe.total == 1)
        #expect(store.value(.codex) == "75%")
        store.tick()
        #expect(!store.allChecking)
        await store.shutdown()
    }

    @Test func clockTickRecoversStaleReadingsAndCoalescesActiveReads() async throws {
        let probe = AllowanceRefreshProbe(held: true)
        let (store, cleanup) = try store(probe)
        defer { cleanup() }
        let old = Date().addingTimeInterval(-1200)
        for provider in Provider.allCases {
            let snapshot = try #require(store.states[provider]?.snapshot)
            store.states[provider]?.apply(.success(
                .init(provider: provider, accountKey: "fixture", allowances: snapshot.allowances, checkedAt: old),
                executable: "Fixture", version: "Test"), at: old)
            #expect(store.value(provider) == "--")
        }
        // Simulate a lost one-shot timer: only the existing clock tick is delivered.
        for _ in 0..<5 { store.tick() }
        try await eventually { await probe.total == 2 }
        #expect(store.allChecking)
        for provider in Provider.allCases { #expect(store.value(provider) == "--") }
        await probe.release()
        try await eventually { !store.allChecking }
        for provider in Provider.allCases { #expect(store.value(provider) == "75%") }
        #expect(await probe.total == 2)
        await store.shutdown()
    }

    @Test func recoveryRespectsBackoffDisabledProvidersSleepAndShutdown() async throws {
        let probe = AllowanceRefreshProbe(held: true)
        let (store, cleanup) = try store(probe, claude: false)
        defer { cleanup() }
        for _ in 0..<3 {
            store.states[.codex]?.apply(
                .failure(.unavailable, accountKey: nil, executable: "Fixture"),
                at: Date().addingTimeInterval(-1200))
        }
        store.tick()
        #expect(!store.allChecking)
        #expect(await probe.total == 0)
        store.sleep()
        store.states[.codex]?.lastAttempt = nil
        store.tick()
        store.refreshAll()
        #expect(!store.allChecking)
        #expect(await probe.total == 0)
        store.wake()
        try await eventually { await probe.total == 1 }
        for _ in 0..<5 { store.tick() }
        #expect(await probe.reads[.claude] == nil)
        store.sleep()
        try await eventually { !store.allChecking }
        await store.shutdown()
        store.tick()
        store.refreshAll()
        #expect(await probe.total == 1)
    }
}
