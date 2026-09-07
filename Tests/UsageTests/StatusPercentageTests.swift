import AppKit
import Testing

@testable import UsageApp

@MainActor struct StatusPercentageTests {
    @Test func percentageDefaultsOnAndSavedChoiceSurvivesReopening() async throws {
        let suite = "SparebarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(demo: true, defaults: defaults)
        #expect(store.showPercentage)
        var statusUpdates = 0
        store.statusChanged = { statusUpdates += 1 }

        store.set(false, for: "showPercentage")
        #expect(!store.showPercentage)
        #expect(statusUpdates == 1)
        await store.shutdown()

        let reopened = UsageStore(demo: true, defaults: defaults)
        #expect(!reopened.showPercentage)
        #expect(reopened.value(.codex) == "64%")
        reopened.set(true, for: "showPercentage")
        #expect(reopened.showPercentage)
        await reopened.shutdown()
    }

    @Test func hidingPercentageReclaimsItsSpaceAcrossStyles() {
        for style in ["number", "bar", "ring"] {
            let shown = StatusLayout(style: style, readings: ["64%", "100%"])
            let hidden = StatusLayout(style: style, showPercentage: false, readings: ["64%", "100%"])
            #expect(shown.width - hidden.width == shown.valueWidth + 3)
            #expect(hidden.width == hidden.iconWidth + hidden.meterWidth)
            #expect(hidden.width == StatusLayout(style: style, showPercentage: false, readings: ["--"]).width)
        }
    }
}
