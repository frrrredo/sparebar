import AppKit
import Foundation
import SwiftUI
import Testing

@testable import UsageApp
@testable import UsageCore
@testable import UsageProviders

private actor ResetIntegrationProbe {
    var redeemed = false
    var consumes = 0
    var reads = 0
    func read(_ provider: Provider) -> ReadOutcome {
        reads += 1
        let snapshot = resetFixture(remaining: redeemed ? 83 : 6, count: redeemed ? 2 : 3).snapshot
        return .success(snapshot, executable: "Synthetic CLI", version: "0.0.0")
    }
    func consume() async -> ResetOutcome {
        consumes += 1
        try? await Task.sleep(for: .milliseconds(80))
        redeemed = true
        return .completed(.reset)
    }
}

@MainActor struct ResetIntegrationTests {
    @Test func nativeActionRereadsProviderAndCoalescesRefreshes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reset integration \(UUID())")
        let suite = "reset-integration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        let probe = ResetIntegrationProbe()
        let resets = ResetController(
            ledger: ResetLedger(directory: dir), consume: { _, _, _ in await probe.consume() })
        let store = UsageStore(
            demo: true, defaults: defaults, resets: resets,
            read: { provider, _ in await probe.read(provider) })
        store.demo = false
        store.set(false, for: "enabled.claude")
        store.refresh(.codex)
        for _ in 0..<100 where store.allChecking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(resets.canOffer)
        resets.ask()
        resets.confirm()
        resets.confirm()
        for _ in 0..<5 { store.refresh(.codex) }
        #expect(await probe.reads == 1)
        for _ in 0..<100 where resets.busy || store.allChecking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.consumes == 1)
        #expect(await probe.reads == 2)
        #expect(store.value(.codex) == "83%")
        #expect(store.states[.codex]?.snapshot?.resetCredits == 2)
        #expect(resets.record.receipts.count == 1)
        #expect(!resets.canOffer)
        await store.shutdown()
    }

    // Opt-in native screenshots use only synthetic accounts, readings and reset receipts.
    @Test func renderSyntheticResetStates() throws {
        guard let destination = ProcessInfo.processInfo.environment["SPAREBAR_RESET_SCREENSHOTS"] else {
            return
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for theme in ["light", "dark"] {
            for scenario in ["low", "healthy", "empty", "confirmation", "pending", "unavailable"] {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "reset-render-\(UUID())")
                let suite = "reset-render-\(UUID())"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer {
                    defaults.removePersistentDomain(forName: suite)
                    try? FileManager.default.removeItem(at: dir)
                }
                let ledger = ResetLedger(directory: dir)
                for _ in 0..<(scenario == "empty" ? 5 : 2) {
                    let attempt = ResetAttempt(accountKey: "fixture", meterID: "weekly")
                    try ledger.begin(attempt)
                    try ledger.finish(attempt, redeemed: true)
                }
                if scenario == "pending" {
                    try ledger.begin(ResetAttempt(accountKey: "fixture", meterID: "weekly"))
                }
                let resets = ResetController(
                    ledger: ledger,
                    consume: { _, _, _ in
                        Issue.record("Screenshot must never redeem a reset")
                        return .notSent(.unavailable)
                    })
                let store = UsageStore(demo: true, defaults: defaults, resets: resets)
                let context = resetFixture(
                    remaining: scenario == "healthy" ? 68 : 6,
                    count: scenario == "empty" ? 0 : scenario == "unavailable" ? nil : 3)
                store.states[.codex]?.apply(
                    .success(context.snapshot, executable: "Synthetic", version: "0.0.0"))
                store.set("", for: "meter.codex")
                if scenario == "confirmation" { resets.ask() }
                let view = PopoverContent(
                    store: store, updates: UpdateController(demo: true), showSettings: {}, quit: {}
                )
                .preferredColorScheme(theme == "dark" ? .dark : .light)
                .transaction { $0.animation = nil }
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                #expect(host.frame.width == 332)
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("reserves-\(scenario)-\(theme).png"))
            }
        }
    }
}
