import Foundation
import SwiftUI
import UsageCore
import UsageProviders

struct ResetContext {
    let snapshot: UsageSnapshot
    let meter: Allowance?
    let current: Bool
    let checking: Bool
    let options: ConnectionOptions
    let configuration: String
    func eligible(at date: Date = Date()) -> Bool {
        current && !checking && date.timeIntervalSince(snapshot.checkedAt) < 900
            && meter.map { !$0.expired(at: date) && $0.remaining <= 10 } == true
            && snapshot.resetCredits.map { $0 > 0 } == true
    }
}

@MainActor final class ResetController: ObservableObject {
    typealias Consume = @Sendable (ResetAttempt, ConnectionOptions, Bool) async -> ResetOutcome
    @Published private(set) var context: ResetContext?
    @Published private(set) var record = ResetRecord()
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var confirmation: ResetContext?
    @Published private(set) var storageReady = true
    @Published private(set) var unsupported = false
    @Published private(set) var awaitingRefresh = false
    @Published private(set) var displayedUsed = 0
    var onChange: (() -> Void)?
    var onFinish: (() -> Void)?
    private let ledger: ResetLedger
    private let consume: Consume
    private var task: Task<Void, Never>?
    private var confirmingRetry = false
    private var confirmedPending: ResetAttempt?
    private var activeAccount: String?
    private var activeConfiguration: String?
    private let demo: Bool
    init(
        ledger: ResetLedger = .standard, demo: Bool = false,
        consume: @escaping Consume = { await CodexReset.consume($0, options: $1, retry: $2) }
    ) {
        self.ledger = ledger
        self.demo = demo
        self.consume = consume
    }
    var canOffer: Bool {
        !demo && !busy && !awaitingRefresh && storageReady && !unsupported && record.pending == nil
            && context?.eligible() == true
    }
    var canRetry: Bool {
        !demo && !busy && storageReady && record.pending != nil && context?.current == true
            && context?.checking == false
    }
    var retryConfirmation: Bool { confirmingRetry }
    var busyInCurrentContext: Bool {
        busy && activeAccount == context?.snapshot.accountKey && activeConfiguration == context?.configuration
    }
    func update(_ next: ResetContext?) {
        let changed =
            context?.snapshot.accountKey != next?.snapshot.accountKey
            || context?.configuration != next?.configuration
        context = next
        if changed {
            confirmation = nil
            message = nil
            unsupported = false
            awaitingRefresh = false
        }
        reloadRecord()
        if awaitingRefresh, next?.checking == false {
            awaitingRefresh = false
            message =
                next?.current == true
                ? "Spare used. Allowance refreshed." : "Spare used. Refresh to check the new allowance."
        }
        if !awaitingRefresh { displayedUsed = record.receipts.count }
        onChange?()
    }
    private func reloadRecord() {
        guard !demo else { return }
        guard let account = context?.snapshot.accountKey else {
            record = ResetRecord()
            return
        }
        do {
            record = try ledger.record(for: account)
            storageReady = true
        } catch {
            record = ResetRecord()
            storageReady = false
            message = "Reset history could not be read. Check again before using a spare."
        }
    }
    func ask(retry: Bool = false) {
        reloadRecord()
        guard retry ? canRetry : canOffer else {
            onChange?()
            return
        }
        confirmingRetry = retry
        confirmedPending = retry ? record.pending : nil
        confirmation = context
        onChange?()
    }
    func cancelConfirmation() {
        confirmation = nil
        onChange?()
    }
    func confirm() {
        guard !demo, !busy, let approved = confirmation, let current = context,
            approved.configuration == current.configuration,
            approved.meter?.id == current.meter?.id,
            approved.snapshot.accountKey == current.snapshot.accountKey
        else {
            cancelConfirmation()
            return
        }
        let retry = confirmingRetry
        reloadRecord()
        guard retry ? (canRetry && record.pending == confirmedPending) : canOffer else {
            cancelConfirmation()
            return
        }
        let attempt =
            retry
            ? record.pending!
            : ResetAttempt(
                accountKey: current.snapshot.accountKey,
                meterID: current.meter?.id ?? "")
        do {
            if !retry { try ledger.begin(attempt) }
        } catch {
            confirmation = nil
            reloadRecord()
            message = "Could not save a new reset request. Check again; no new request was sent."
            onChange?()
            return
        }
        record.pending = attempt
        confirmation = nil
        activeAccount = current.snapshot.accountKey
        activeConfiguration = current.configuration
        busy = true
        message = "Using your spare..."
        onChange?()
        let consume = self.consume
        task = Task { [weak self] in
            let result = await consume(attempt, current.options, retry)
            guard let self else { return }
            let matchesCurrent =
                self.context?.snapshot.accountKey == attempt.accountKey
                && self.context?.configuration == current.configuration
            var text: String
            do {
                switch result {
                case .completed(let outcome):
                    try self.ledger.finish(attempt, redeemed: outcome.redeemed)
                    if outcome.redeemed, matchesCurrent {
                        self.awaitingRefresh = true
                    }
                    switch outcome {
                    case .reset, .alreadyRedeemed: text = "Spare used. Checking your refreshed allowance..."
                    case .noCredit: text = "No spare is available now. Checking your reserve..."
                    case .nothingToReset: text = "No reset was needed. Your spare was kept."
                    }
                case .notSent(let issue):
                    // A retry that fails before sending cannot resolve an earlier uncertain call.
                    if !retry { try self.ledger.finish(attempt, redeemed: false) }
                    if issue == .unsupported {
                        if matchesCurrent { self.unsupported = true }
                        text = "Update Codex CLI to use spares from Sparebar."
                    } else {
                        text = "Could not complete the reset check. \(issue.message)."
                    }
                case .uncertain:
                    text =
                        "The reset result is unconfirmed. Retry the saved request to avoid using another spare."
                }
            } catch {
                text = "The reset receipt could not be saved. Retry the saved request to confirm its result."
            }
            self.busy = false
            self.task = nil
            self.activeAccount = nil
            self.activeConfiguration = nil
            if matchesCurrent {
                self.message = text
                self.reloadRecord()
            }
            self.onChange?()
            self.onFinish?()
        }
    }
    func dismissMessage() {
        message = nil
        onChange?()
    }
    func sleep() { task?.cancel() }
    func shutdown() async {
        task?.cancel()
        await task?.value
    }
}
