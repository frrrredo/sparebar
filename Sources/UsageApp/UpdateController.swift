import AppKit
import Sparkle
import SwiftUI

/// Sparkle owns the update transaction; Sparebar presents it in the existing panel.
@MainActor final class UpdateController: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    enum Phase: Equatable {
        case idle, checking, available, downloading, verifying, ready, installing, current, failed,
            information
    }

    @Published private(set) var phase: Phase = .idle { didSet { statusChanged?() } }
    @Published private(set) var version = ""
    @Published private(set) var progress: Double?
    @Published private(set) var automaticUpdates = true
    @Published private(set) var summary = "A fresh version of Sparebar is available."
    @Published private(set) var releaseNotes = ""
    @Published private(set) var message = ""
    var statusChanged: (() -> Void)?
    var present: (() -> Void)?
    private let demo: Bool
    private let bundle: Bundle
    private var engine: SPUUpdater?
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var restartAuthorized = false
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var manuallyChecking = false
    private var cancelled = false

    init(demo: Bool = false, bundle: Bundle = .main) {
        self.demo = demo
        self.bundle = bundle
        super.init()
    }

    var hasUpdate: Bool {
        [.available, .downloading, .verifying, .ready, .installing, .information].contains(phase)
    }
    var busy: Bool { [.checking, .downloading, .verifying, .installing].contains(phase) }
    var canCancel: Bool { cancellation != nil && [.checking, .downloading].contains(phase) }
    var visible: Bool { hasUpdate || busy || phase == .current || (phase == .failed && manuallyChecking) }
    var title: String {
        switch phase {
        case .idle: "Software updates"
        case .checking: "Checking for updates..."
        case .available: "Sparebar \(version) is available"
        case .downloading: "Downloading update..."
        case .verifying: "Verifying update..."
        case .ready: "Ready when you are"
        case .installing: "Installing and restarting..."
        case .current: "Sparebar is up to date"
        case .failed: "Could not update Sparebar"
        case .information: "Update information available"
        }
    }
    var tooltip: String { hasUpdate ? "Update available. Open Sparebar to update and restart." : "" }

    func start() {
        guard !demo, engine == nil, bundle.bundleURL.pathExtension == "app" else { return }
        let updater = SPUUpdater(
            hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        engine = updater
        do {
            try updater.start()
            automaticUpdates = updater.automaticallyDownloadsUpdates
        } catch {
            message = "Update checking is unavailable. Try reopening Sparebar."
            phase = .failed
        }
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        guard !demo, let engine else { return }
        engine.automaticallyDownloadsUpdates = enabled
        automaticUpdates = engine.automaticallyDownloadsUpdates
    }

    func check() {
        manuallyChecking = true
        present?()
        guard !demo, !busy else { return }
        if hasUpdate { return }
        guard let engine, engine.canCheckForUpdates else {
            message = "Update checking is unavailable. Try reopening Sparebar."
            phase = .failed
            return
        }
        cancelled = false
        engine.checkForUpdates()
    }

    func install() {
        guard phase == .available || phase == .ready else { return }
        let reply = choice
        choice = nil
        manuallyChecking = true
        restartAuthorized = true
        cancelled = false
        progress = nil
        if let reply {
            phase = phase == .ready ? .installing : .downloading
            reply(.install)
        } else if let engine, engine.canCheckForUpdates {
            // A background update is already staged. Sparkle reopens that transaction.
            engine.checkForUpdates()
        } else if demo {
            phase = .downloading
        }
    }

    func cancel() {
        guard canCancel, let cancel = cancellation else { return }
        cancellation = nil
        restartAuthorized = false
        cancelled = true
        phase = .idle
        cancel()
    }

    func showInformation() {
        guard phase == .information else { return }
        // Do not navigate to arbitrary URLs supplied by an update feed.
        NSWorkspace.shared.open(URL(string: "https://github.com/frrrredo/sparebar/releases")!)
        let reply = choice
        choice = nil
        phase = .idle
        reply?(.dismiss)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        progress = nil
        phase = .checking
    }
    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        cancellation = nil
        use(appcastItem)
        choice = reply
        if appcastItem.isInformationOnlyUpdate {
            restartAuthorized = false
            phase = .information
        } else if restartAuthorized {
            choice = nil
            phase = state.stage == .installing ? .installing : .downloading
            reply(.install)
        } else {
            phase = state.stage == .notDownloaded ? .available : .ready
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        // Sparkle distinguishes an unsupported OS from already having the newest build.
        let reason =
            ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
            ?? SPUNoUpdateFoundReason.unknown.rawValue
        if reason == SPUNoUpdateFoundReason.onLatestVersion.rawValue
            || reason == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue
        {
            phase = .current
        } else {
            message = "No compatible update is available for this Mac."
            phase = .failed
        }
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        restartAuthorized = false
        if !cancelled {
            message = "The update could not finish. Check your connection and try again."
            phase = .failed
        }
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expectedBytes = 0
        receivedBytes = 0
        progress = nil
        phase = .downloading
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
        updateProgress()
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let sum = receivedBytes.addingReportingOverflow(length)
        receivedBytes = sum.overflow ? UInt64.max : sum.partialValue
        updateProgress()
    }
    private func updateProgress() {
        progress = expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : nil
    }
    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        progress = nil
        phase = .verifying
    }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if restartAuthorized {
            phase = .installing
            reply(.install)
        } else {
            choice = reply
            phase = .ready
        }
    }
    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        phase = .installing
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }
    func dismissUpdateInstallation() {
        choice = nil
        cancellation = nil
        restartAuthorized = false
        if phase != .failed && phase != .current && phase != .ready { phase = .idle }
    }
    func showUpdateInFocus() { present?() }
    private func use(_ item: SUAppcastItem) {
        version = String(item.displayVersionString.prefix(32))
        let notes = ReleaseNotes(item.itemDescription ?? "")
        summary = notes.summary
        releaseNotes = notes.details
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        manuallyChecking = updateCheck == .updates
        cancelled = false
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        use(item)
        if !busy && phase != .ready { phase = .available }
    }
    func updater(
        _ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest
    ) {
        use(item)
        progress = nil
        phase = .downloading
    }
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        use(item)
        if restartAuthorized {
            phase = .installing
            Task { @MainActor in immediateInstallHandler() }
            return true
        }
        phase = .ready
        // Keep Sparkle's scheduler alive. Only the user's button requests a relaunch.
        return false
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool
    { false }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error, !cancelled, phase != .current else { return }
        // Background failures remain quiet but can be inspected in Settings.
        if (error as NSError).code != SUError.noUpdateError.rawValue {
            message = "Update checking failed. Check your connection and try again."
            phase = .failed
        }
    }

    /// Synthetic presentation only; it never starts Sparkle or accesses the network.
    func showDemoUpdate(phase: Phase = .available) {
        guard demo else { return }
        version = "0.2.0"
        summary = "Sparebar keeps itself fresh - one less thing to remember."
        releaseNotes =
            "Updates download in the background and install when you quit.\n\nWant the new version now? Choose Update and Restart.\n\nTurn automatic updates off in Settings if you prefer to choose each download."
        if phase == .failed {
            manuallyChecking = true
            message = "The update could not finish. Check your connection and try again."
        }
        self.phase = phase
    }
}

struct ReleaseNotes {
    let summary: String
    let details: String
    init(_ text: String) {
        let clean = String(text.prefix(12_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        let first = clean.components(separatedBy: .newlines).first ?? ""
        summary = first.isEmpty ? "A fresh version of Sparebar is available." : String(first.prefix(180))
        details = clean.isEmpty ? "Release notes are not available for this update." : clean
    }
}
