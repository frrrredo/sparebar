import AppKit
import Sparkle
import Testing

@testable import UsageApp

@MainActor struct UpdateControllerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPAREBAR_UPDATER_FIXTURE"] != nil))
    func localAppcastPassesThroughTheRealSparkleDriver() async throws {
        guard let path = ProcessInfo.processInfo.environment["SPAREBAR_UPDATER_FIXTURE"] else { return }
        let bundle = try #require(Bundle(path: path))
        let updates = UpdateController(bundle: bundle)
        updates.start()
        updates.check()
        for _ in 0..<100 {
            if updates.phase == .available || updates.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(updates.phase == .available, "\(updates.message)")
        #expect(updates.version == "0.1.4")
        #expect(updates.summary == "Less clicking.")
        #expect(updates.releaseNotes.contains("User-friendly details."))
        #expect(!updates.busy)
        if ProcessInfo.processInfo.environment["SPAREBAR_UPDATER_REJECT_DOWNLOAD"] == "1" {
            updates.install()
            for _ in 0..<100 {
                if updates.phase == .failed { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(updates.phase == .failed)
            #expect(!updates.hasUpdate)
        }
    }
    @Test func optionalSparkleCallbacksAreExposedToObjectiveC() {
        let updates = UpdateController(demo: true)
        for selector in [
            "updater:didFindValidUpdate:", "updater:willDownloadUpdate:withRequest:",
            "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
            "updater:shouldDownloadReleaseNotesForUpdate:",
            "updater:didFinishUpdateCycleForUpdateCheck:error:",
            "updater:mayPerformUpdateCheck:error:",
        ] {
            #expect(
                updates.responds(to: NSSelectorFromString(selector)), "Missing Sparkle callback: \(selector)")
        }
    }
    @Test func laterBackgroundFailuresStayQuietAfterAManualCheck() throws {
        let updates = UpdateController(demo: true)
        let engine = SPUUpdater(
            hostBundle: .main, applicationBundle: .main, userDriver: updates, delegate: updates)
        updates.check()
        updates.showUpdaterError(NSError(domain: "fixture", code: 1)) {}
        #expect(updates.visible)
        try updates.updater(engine, mayPerform: .updatesInBackground)
        updates.showUpdaterError(NSError(domain: "fixture", code: 1)) {}
        #expect(!updates.visible)
    }
    @Test func preparedUpdateWaitsForUserBeforeRestarting() {
        let updates = UpdateController(demo: true)
        var installs = 0
        updates.showReady { choice in if choice == .install { installs += 1 } }
        #expect(updates.phase == .ready)
        #expect(updates.hasUpdate)
        #expect(installs == 0)
        updates.install()
        #expect(installs == 1)
        updates.install()
        #expect(installs == 1)
    }

    @Test func userClickAuthorizesTheRemainingCycleWithoutAnotherPrompt() {
        let updates = UpdateController(demo: true)
        updates.showReady { _ in }
        updates.install()
        var decision: SPUUserUpdateChoice?
        updates.showReady { decision = $0 }
        #expect(decision == .install)
        #expect(updates.phase == .installing)
    }

    @Test func cancelledDownloadCannotAuthorizeARestart() {
        let updates = UpdateController(demo: true)
        updates.showReady { _ in }
        updates.install()
        var cancellations = 0
        updates.showDownloadInitiated { cancellations += 1 }
        updates.cancel()
        updates.cancel()
        #expect(cancellations == 1)
        #expect(!updates.hasUpdate)
        var restarted = false
        updates.showReady { _ in restarted = true }
        #expect(!restarted)
    }

    @Test func downloadProgressHandlesUnknownLengthAndOverflow() {
        let updates = UpdateController(demo: true)
        updates.showDownloadInitiated {}
        updates.showDownloadDidReceiveData(ofLength: 20)
        #expect(updates.progress == nil)
        updates.showDownloadDidReceiveExpectedContentLength(100)
        #expect(updates.progress == 0.2)
        updates.showDownloadDidReceiveData(ofLength: UInt64.max)
        #expect(updates.progress == 1)
    }

    @Test func errorsDoNotClaimAnUpdateSucceeded() {
        let updates = UpdateController(demo: true)
        var acknowledged = false
        updates.showUpdaterError(NSError(domain: "fixture", code: 1)) { acknowledged = true }
        updates.dismissUpdateInstallation()
        #expect(acknowledged)
        #expect(updates.phase == .failed)
        #expect(!updates.hasUpdate)
    }

    @Test func releaseNotesStayBoundedAndMissingNotesStayHonest() {
        let notes = ReleaseNotes("A little less clicking.\n\nUpdate details.")
        #expect(notes.summary == "A little less clicking.")
        #expect(notes.details.contains("Update details."))
        #expect(ReleaseNotes(String(repeating: "x", count: 20_000)).summary.count == 180)
        #expect(ReleaseNotes(String(repeating: "x", count: 20_000)).details.count == 12_000)
        #expect(ReleaseNotes("").details == "Release notes are not available for this update.")
    }
}
