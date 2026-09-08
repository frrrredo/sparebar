import Foundation

public enum ServiceHealthLevel: Int, Equatable, Sendable {
    case operational, degraded, outage, unknown

    public var hasIncident: Bool { self == .degraded || self == .outage }
    public var label: String {
        switch self {
        case .operational: "Operational"
        case .degraded: "Degraded"
        case .outage: "Outage reported"
        case .unknown: "Unknown"
        }
    }
    public init(componentStatus: String) {
        switch componentStatus {
        case "operational": self = .operational
        case "degraded_performance", "under_maintenance": self = .degraded
        case "partial_outage", "major_outage", "full_outage": self = .outage
        default: self = .unknown
        }
    }
}

extension Provider {
    public var serviceName: String { self == .codex ? "OpenAI" : "Claude" }
    public var statusURL: URL {
        URL(string: self == .codex ? "https://status.openai.com/" : "https://status.claude.com/")!
    }
    public var statusFeedURL: URL {
        statusURL.appending(path: self == .codex ? "proxy/status.openai.com" : "api/v2/summary.json")
    }
}

public struct ServiceComponent: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let status: String
    public let group: Bool?
    public var level: ServiceHealthLevel { .init(componentStatus: status) }
    public var label: String { status == "under_maintenance" ? "Maintenance" : level.label }
    public var displayName: String { serviceText(name, limit: 100) }
    public init(id: String, name: String, status: String, group: Bool? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.group = group
    }
}

public struct ServiceIncident: Decodable, Equatable, Sendable, Identifiable {
    public struct ComponentReference: Decodable, Equatable, Sendable {
        public let id: String
    }
    public let id: String
    public let name: String
    public let status: String
    public let impact: String
    public let components: [ComponentReference]?
    public var componentIDs: Set<String> { Set((components ?? []).map(\.id)) }
    public var active: Bool { !["resolved", "postmortem"].contains(status) }
    public var displayName: String { serviceText(name, limit: 180) }
    public var level: ServiceHealthLevel {
        guard active else { return .operational }
        guard ["investigating", "identified", "monitoring"].contains(status) else { return .unknown }
        switch impact {
        case "major", "critical": return .outage
        case "none", "minor": return .degraded
        default: return .unknown
        }
    }
    public init(id: String, name: String, status: String, impact: String, componentIDs: Set<String> = []) {
        self.id = id
        self.name = name
        self.status = status
        self.impact = impact
        self.components = componentIDs.sorted().map { .init(id: $0) }
    }
}

private func serviceText(_ text: String, limit: Int) -> String {
    String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        .map(String.init).joined().prefix(limit))
}

public struct ServiceHealthSnapshot: Equatable, Sendable {
    public let components: [ServiceComponent]
    public let incidents: [ServiceIncident]
    public let indicator: String?
    public let groups: [WatchedService]
    public let unscopedIncidents: [ServiceIncident]
    public let scopeIncomplete: Bool
    public var affected: [ServiceComponent] { components.filter { $0.level.hasIncident } }
    public var level: ServiceHealthLevel {
        guard !components.isEmpty || !incidents.isEmpty else { return .unknown }
        var levels = components.map(\.level) + incidents.map(\.level)
        if scopeIncomplete || !unscopedIncidents.isEmpty { levels.append(.unknown) }
        if let indicator {
            let rollup: ServiceHealthLevel = switch indicator {
            case "none": .operational
            case "minor": .degraded
            case "major", "critical": .outage
            default: .unknown
            }
            levels.append(rollup)
        }
        // A known incident remains visible even if another component cannot be interpreted.
        if levels.contains(.outage) { return .outage }
        if levels.contains(.degraded) { return .degraded }
        return levels.isEmpty || levels.contains(.unknown) ? .unknown : .operational
    }
    public init(components: [ServiceComponent], incidents: [ServiceIncident] = [], indicator: String? = nil,
                groups: [WatchedService] = [],
                unscopedIncidents: [ServiceIncident] = [], scopeIncomplete: Bool = false) {
        self.components = components.filter { $0.group != true }
        self.incidents = incidents.filter(\.active)
        self.indicator = indicator
        self.groups = groups
        self.unscopedIncidents = unscopedIncidents.filter(\.active)
        self.scopeIncomplete = scopeIncomplete
    }
    public init(data: Data) throws {
        struct Document: Decodable {
            struct Rollup: Decodable { let indicator: String }
            let components: [ServiceComponent]
            let incidents: [ServiceIncident]
            let status: Rollup?
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.components.count <= 200, document.incidents.count <= 100,
            Set(document.components.map(\.id)).count == document.components.count,
            Set(document.incidents.map(\.id)).count == document.incidents.count
        else { throw ServiceHealthError.malformed }
        self.init(components: document.components, incidents: document.incidents, indicator: document.status?.indicator)
    }
    public func hasNewOrWorseIncident(than old: Self) -> Bool {
        if level.hasIncident && (!old.level.hasIncident || level.rawValue > old.level.rawValue) { return true }
        let previousIncidents = Dictionary(uniqueKeysWithValues: old.incidents.map { ($0.id, $0.level) })
        let previousComponents = Dictionary(uniqueKeysWithValues: old.components.map { ($0.id, $0.level) })
        return incidents.contains { incident in
            incident.level.hasIncident && (previousIncidents[incident.id]?.hasIncident != true
                || incident.level.rawValue > previousIncidents[incident.id]!.rawValue)
        } || affected.contains { component in
            previousComponents[component.id]?.hasIncident != true
                || component.level.rawValue > previousComponents[component.id]!.rawValue
        }
    }
}

public enum ServiceHealthError: Error, Sendable {
    case malformed, responseTooLarge, unavailable
    case http(Int, retryAfter: TimeInterval?)
    public var retryAfter: TimeInterval? {
        if case .http(_, let delay) = self { return delay }
        return nil
    }
}

public struct ServiceHealthSignal: Equatable, Sendable {
    public enum Kind: Sendable { case alert, recovery }
    public let sequence: Int
    public let kind: Kind
    public let date: Date
}

public struct ServiceHealthState: Sendable {
    public static let freshness: TimeInterval = 600
    public static let reminderInterval: TimeInterval = 600
    public private(set) var snapshot: ServiceHealthSnapshot?
    public private(set) var checkedAt: Date?
    public private(set) var failed = false
    public private(set) var failures = 0
    public private(set) var acknowledged = false
    public private(set) var nextReminder: Date?
    public private(set) var signal: ServiceHealthSignal?
    private var confirmed: ServiceHealthSnapshot?
    private var sequence = 0
    public init() {}

    public func level(at date: Date) -> ServiceHealthLevel {
        guard !failed, let checkedAt, date.timeIntervalSince(checkedAt) < Self.freshness else { return .unknown }
        return snapshot?.level ?? .unknown
    }
    public mutating func apply(_ fresh: ServiceHealthSnapshot, at date: Date, reading: Bool = false) {
        let previous = confirmed
        snapshot = fresh
        checkedAt = date
        failed = false
        failures = 0
        // An uninterpretable report pauses reminders without losing acknowledgment
        // or the last confirmed incident needed to recognize a later recovery.
        guard fresh.level != .unknown else { signal = nil; return }
        confirmed = fresh
        if fresh.level.hasIncident {
            if previous == nil || fresh.hasNewOrWorseIncident(than: previous!) {
                acknowledged = reading
                emit(.alert, at: date)
                nextReminder = fresh.level == .outage ? date.addingTimeInterval(Self.reminderInterval) : nil
            }
            if fresh.level != .outage { nextReminder = nil }
            if reading { acknowledge() }
        } else {
            nextReminder = nil
            acknowledged = false
            if fresh.level == .operational, previous?.level.hasIncident == true { emit(.recovery, at: date) }
        }
    }
    public mutating func fail() {
        failed = true
        failures = min(failures + 1, 10)
        signal = nil
    }
    /// A preference edit reuses the last result without becoming a new check or recovery.
    public mutating func reproject(_ filtered: ServiceHealthSnapshot?) {
        snapshot = filtered
        confirmed = filtered.flatMap { $0.level == .unknown ? nil : $0 }
        signal = nil
        nextReminder = nil
        acknowledged = true
    }
    public mutating func acknowledge() {
        acknowledged = true
        nextReminder = nil
    }
    @discardableResult public mutating func remind(at date: Date) -> Bool {
        guard level(at: date) == .outage, !acknowledged,
            let nextReminder, date >= nextReminder else { return false }
        emit(.alert, at: date)
        self.nextReminder = date.addingTimeInterval(Self.reminderInterval)
        return true
    }
    private mutating func emit(_ kind: ServiceHealthSignal.Kind, at date: Date) {
        sequence += 1
        signal = .init(sequence: sequence, kind: kind, date: date)
    }
    public func retryDelay(serverDelay: TimeInterval? = nil) -> TimeInterval {
        max(min(3600, 300 * pow(2, Double(min(failures, 4)))), max(0, serverDelay ?? 0))
    }
}
