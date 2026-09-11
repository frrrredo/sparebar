import Foundation

public struct ResetCredit: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let expiresAt: Date?
    public init(id: String, title: String, description: String? = nil, expiresAt: Date? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.expiresAt = expiresAt
    }
}

public struct ResetAttempt: Codable, Equatable, Sendable {
    public let id: String
    public let accountKey: String
    public let meterID: String
    public let createdAt: Date
    public init(id: String = UUID().uuidString, accountKey: String, meterID: String, createdAt: Date = Date())
    {
        self.id = id
        self.accountKey = accountKey
        self.meterID = meterID
        self.createdAt = createdAt
    }
}

public enum ResetDisposition: String, Sendable {
    case reset, alreadyRedeemed, nothingToReset, noCredit
    public var redeemed: Bool { self == .reset || self == .alreadyRedeemed }
}

public enum ResetOutcome: Sendable {
    case completed(ResetDisposition)
    case notSent(UsageIssue)
    // The caller must retain the attempt and reuse its ID, even after restart.
    case uncertain(UsageIssue)
}
