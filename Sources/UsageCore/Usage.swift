import Foundation

public enum Provider: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex, claude
    public var id: String { rawValue }
    public var name: String { self == .codex ? "Codex" : "Claude" }
    public var cliName: String { self == .codex ? "Codex CLI" : "Claude Code" }
    public var setupURL: URL {
        URL(
            string: self == .codex
                ? "https://learn.chatgpt.com/docs/cli" : "https://code.claude.com/docs/en/setup")!
    }
}

public struct Allowance: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let used: Double
    public let resetsAt: Date?
    public let weekly: Bool
    public let isMain: Bool
    public var remaining: Double { 100 - used }
    public init(id: String, label: String, used: Double, resetsAt: Date?, weekly: Bool, isMain: Bool) {
        self.id = id
        self.label = label
        self.used = used
        self.resetsAt = resetsAt
        self.weekly = weekly
        self.isMain = isMain
    }
    public func expired(at date: Date) -> Bool { resetsAt.map { $0 <= date } ?? false }
}

public struct UsageSnapshot: Sendable {
    public let provider: Provider
    // One-way account association; also scopes the local reset receipt ledger.
    public let accountKey: String
    public let allowances: [Allowance]
    public let checkedAt: Date
    public let resetCredits: Int?
    public let resetDetails: [ResetCredit]
    public let accountLabel: String?
    public init(
        provider: Provider, accountKey: String, allowances: [Allowance], checkedAt: Date = Date(),
        resetCredits: Int? = nil, resetDetails: [ResetCredit] = [], accountLabel: String? = nil
    ) {
        self.provider = provider
        self.accountKey = accountKey
        self.allowances = allowances
        self.checkedAt = checkedAt
        self.resetCredits = resetCredits
        self.resetDetails = resetDetails
        self.accountLabel = accountLabel
    }
    public var preferred: Allowance? {
        allowances.first { $0.weekly && $0.isMain } ?? allowances.first { $0.isMain } ?? allowances.first
    }
}

public enum UsageIssue: String, Error, Sendable {
    case missingCLI, signIn, subscriptionRequired, unavailable, unsupported, malformed, timeout, outputLimit,
        cancelled, helperExited, unexpectedMessage, accountChanged, launchFailed
    public var message: String {
        switch self {
        case .missingCLI: "Tool not found"
        case .signIn: "Sign in through the official tool"
        case .subscriptionRequired: "A subscription account is required"
        case .unavailable: "Allowance is unavailable"
        case .unsupported: "This tool version does not support usage reads"
        case .malformed: "The tool returned an unreadable allowance"
        case .timeout: "The usage check timed out"
        case .outputLimit: "The tool returned too much output"
        case .cancelled: "Usage check cancelled"
        case .helperExited: "The tool stopped before returning usage"
        case .unexpectedMessage: "The tool requested an unexpected action"
        case .accountChanged: "Account changed; check again"
        case .launchFailed: "The tool could not start"
        }
    }
}

public enum ReadOutcome: Sendable {
    case success(UsageSnapshot, executable: String, version: String)
    case failure(UsageIssue, accountKey: String?, executable: String?)
}

public struct ProviderState: Sendable {
    public var snapshot: UsageSnapshot?
    public var issue: UsageIssue?
    public var executable: String?
    public var version: String?
    public var checking = false
    public var failures = 0
    public var lastAttempt: Date?
    public init() {}
    public mutating func apply(_ outcome: ReadOutcome, at date: Date = Date()) {
        checking = false
        lastAttempt = date
        switch outcome {
        case .success(let snapshot, let executable, let version):
            self.snapshot = snapshot
            self.executable = executable
            self.version = version
            issue = nil
            failures = 0
        case .failure(let issue, let identity, let executable):
            self.issue = issue
            self.executable = executable
            failures += 1
            // Old values survive only a failed read of the same verified account.
            if identity == nil || identity != snapshot?.accountKey
                || [.signIn, .accountChanged, .subscriptionRequired].contains(issue)
            {
                snapshot = nil
            }
        }
    }
    public func meter(selected: String?) -> Allowance? {
        guard let snapshot else { return nil }
        // A disappeared chosen model must not silently become a different allowance.
        if let selected, !selected.isEmpty { return snapshot.allowances.first { $0.id == selected } }
        return snapshot.preferred
    }
    public func isCurrent(_ meter: Allowance?, at date: Date = Date()) -> Bool {
        guard issue == nil, let meter, let snapshot else { return false }
        return !meter.expired(at: date) && date.timeIntervalSince(snapshot.checkedAt) < 900
    }
    public var retryDelay: TimeInterval { min(1800, 300 * pow(2, Double(min(failures, 3)))) }
}

public enum Severity: Int, Comparable, Sendable {
    case normal, unavailable, low, critical
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public static func remaining(_ value: Double?) -> Self {
        guard let value else { return .unavailable }
        return value <= 10 ? .critical : value <= 20 ? .low : .normal
    }
}
