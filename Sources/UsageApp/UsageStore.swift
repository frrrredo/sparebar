import AppKit
import SwiftUI
import UsageCore
import UsageProviders

@MainActor final class UsageStore: ObservableObject {
    @Published var states = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderState()) })
    @Published var currentIndex = 0
    @Published var popoverOpen = false {
        didSet { health.reading = popoverOpen }
    }
    @Published var now = Date()
    @Published var demo: Bool
    let health: ServiceHealthController
    var statusChanged: (() -> Void)?
    private let defaults: UserDefaults
    private var reads: [Provider: Task<Void, Never>] = [:]
    private var revisions: [Provider: Int] = [:]
    private var refreshTimer: Task<Void, Never>?
    private var rotationTimer: Task<Void, Never>?
    private var clockTimer: Task<Void, Never>?
    private var sleeping = false
    private var stopping = false

    init(demo: Bool, defaults: UserDefaults = .standard) {
        self.demo = demo
        self.defaults = defaults
        self.health = ServiceHealthController(demo: demo)
        let installed =
            demo
            ? Provider.allCases
            : Provider.allCases.filter {
                CLIDiscovery.resolve($0, custom: preference("path.\($0.rawValue)")) != nil
            }
        defaults.register(defaults: [
            "rotation": true, "interval": 5, "style": "number", "remaining": true,
            "showPercentage": true,
            "enabled.codex": installed.isEmpty || installed.contains(.codex),
            "enabled.claude": installed.isEmpty || installed.contains(.claude),
        ])
        if demo {
            for provider in Provider.allCases {
                let value = provider == .codex ? 36.0 : 82.0
                let meters = [
                    Allowance(
                        id: "weekly", label: "Weekly", used: value,
                        resetsAt: Date().addingTimeInterval(23_400), weekly: true, isMain: true),
                    Allowance(
                        id: "session", label: "5-hour", used: 12, resetsAt: Date().addingTimeInterval(7_200),
                        weekly: false, isMain: true),
                ]
                states[provider]?.apply(
                    .success(
                        .init(provider: provider, accountKey: "demo", allowances: meters),
                        executable: "Sample data", version: "Demo"))
            }
        }
        health.onChange = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.now = Date()
            self.statusChanged?()
        }
    }
    var providers: [Provider] { Provider.allCases.filter { defaults.bool(forKey: "enabled.\($0.rawValue)") } }
    var current: Provider? { providers.isEmpty ? nil : providers[currentIndex % providers.count] }
    var rotating: Bool { defaults.bool(forKey: "rotation") }
    var interval: Int {
        [3, 5, 10, 15].contains(defaults.integer(forKey: "interval"))
            ? defaults.integer(forKey: "interval") : 5
    }
    var style: String { defaults.string(forKey: "style") ?? "number" }
    var showRemaining: Bool { defaults.bool(forKey: "remaining") }
    var showPercentage: Bool { defaults.bool(forKey: "showPercentage") }
    var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var differentiateWithoutColor: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }
    var allChecking: Bool { states.values.contains { $0.checking } }
    var rotationLabel: String {
        if providers.count < 2 {
            return providers.isEmpty ? "Choose a tool in Settings" : "One connected tool"
        }
        if reducedMotion { return "Reduced motion: manual switching" }
        if !rotating { return "Rotation paused" }
        return popoverOpen ? "Paused while reading" : "Rotating every \(interval) seconds"
    }
    func enabled(_ provider: Provider) -> Bool { providers.contains(provider) }
    func preference(_ key: String) -> String { defaults.string(forKey: key) ?? "" }
    func set(_ value: Any, for key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        currentIndex = min(currentIndex, max(0, providers.count - 1))
        startRotation()
        statusChanged?()
    }
    func setEnabled(_ value: Bool, provider: Provider) {
        set(value, for: "enabled.\(provider.rawValue)")
        health.setProviders(providers)
        if value {
            states[provider]?.lastAttempt = nil
            refresh(provider)
        } else {
            reads[provider]?.cancel()
        }
        schedule()
    }
    func selected(_ provider: Provider) -> String { preference("meter.\(provider.rawValue)") }
    func meter(_ provider: Provider) -> Allowance? { states[provider]?.meter(selected: selected(provider)) }
    func valid(_ provider: Provider) -> Bool {
        states[provider]?.isCurrent(meter(provider), at: now) ?? false
    }
    func displayAmount(_ provider: Provider) -> Double? {
        guard valid(provider), let meter = meter(provider) else { return nil }
        return showRemaining ? meter.remaining : meter.used
    }
    func value(_ provider: Provider) -> String {
        guard let amount = displayAmount(provider) else { return "--" }
        return "\(Int(amount.rounded()))%"
    }
    func severity(_ provider: Provider) -> Severity {
        .remaining(valid(provider) ? meter(provider)?.remaining : nil)
    }
    var warning: Severity { providers.map(severity).max() ?? .unavailable }
    var warningText: String {
        let sorted = providers.sorted { severity($0) > severity($1) }
        guard let provider = sorted.first else { return "Enable a tool in Settings." }
        switch severity(provider) {
        case .critical: return "\(provider.name) allowance is very low."
        case .low: return "\(provider.name) allowance is running low."
        case .unavailable:
            if let issue = states[provider]?.issue,
                [.missingCLI, .signIn, .subscriptionRequired].contains(issue)
            {
                return "\(provider.name) needs setup."
            }
            return "\(provider.name) allowance needs a refresh."
        case .normal: return "No low allowances."
        }
    }
    func detail(_ provider: Provider) -> String {
        let state = states[provider] ?? .init()
        if let issue = state.issue { return issue.message }
        if let meter = meter(provider), meter.expired(at: now) {
            return "Reset reached; waiting for a new reading"
        }
        if state.snapshot != nil, meter(provider) == nil { return "Selected allowance is no longer returned" }
        if let snapshot = state.snapshot, now.timeIntervalSince(snapshot.checkedAt) >= 900 {
            return "Reading is old; refresh to check allowance"
        }
        if state.checking && state.snapshot == nil { return "Checking connection..." }
        return state.snapshot == nil ? "Waiting for a usage check" : "Connected"
    }
    func advance() {
        guard providers.count > 1 else { return }
        withAnimation(reducedMotion ? nil : .smooth(duration: 0.35)) {
            currentIndex = (currentIndex + 1) % providers.count
        }
        statusChanged?()
    }
    func start() {
        health.start(providers: providers)
        startRotation()
        if !demo { refreshAll() }
        clockTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, !self.stopping else { return }
                if !self.sleeping {
                    self.now = Date()
                    self.statusChanged?()
                }
            }
        }
    }
    private func startRotation() {
        rotationTimer?.cancel()
        guard rotating, !reducedMotion, !sleeping, !stopping, providers.count > 1 else { return }
        rotationTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(self.interval)) } catch { return }
                if !self.popoverOpen { self.advance() }
            }
        }
    }
    func refreshAll() { for provider in providers { refresh(provider) } }
    func refresh(_ provider: Provider) {
        guard !demo, !sleeping, !stopping, enabled(provider), reads[provider] == nil else { return }
        states[provider]?.checking = true
        now = Date()
        statusChanged?()
        let revision = revisions[provider, default: 0]
        let options = ConnectionOptions(
            executable: preference("path.\(provider.rawValue)"),
            configDirectory: preference("root.\(provider.rawValue)"))
        reads[provider] = Task { [weak self] in
            let outcome = await ProviderReader.read(provider, options: options)
            guard let self else { return }
            self.reads[provider] = nil
            self.states[provider]?.checking = false
            if !Task.isCancelled, self.enabled(provider), revision == self.revisions[provider, default: 0] {
                self.states[provider]?.apply(outcome)
                self.now = Date()
                self.statusChanged?()
            }
            if revision != self.revisions[provider, default: 0] { self.refresh(provider) }
            self.schedule()
        }
    }
    func applyConnection(_ provider: Provider, path: String, root: String) {
        defaults.set(
            path.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "path.\(provider.rawValue)")
        defaults.set(
            root.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "root.\(provider.rawValue)")
        revisions[provider, default: 0] += 1
        states[provider] = .init()
        if let read = reads[provider] { read.cancel() } else { refresh(provider) }
        statusChanged?()
    }
    private func due(_ provider: Provider) -> Date {
        let state = states[provider] ?? .init()
        guard let last = state.lastAttempt else { return .distantPast }
        var due = last.addingTimeInterval(state.issue == nil ? 300 : state.retryDelay)
        for meter in state.snapshot?.allowances ?? [] {
            if let reset = meter.resetsAt, reset > last { due = min(due, reset.addingTimeInterval(1)) }
        }
        return due
    }
    private func schedule() {
        refreshTimer?.cancel()
        guard !demo, !sleeping, !stopping,
            let next = providers.filter({ reads[$0] == nil }).map(due).min()
        else { return }
        refreshTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.2, next.timeIntervalSinceNow))) } catch { return }
            guard let self else { return }
            for provider in self.providers where self.due(provider) <= Date() { self.refresh(provider) }
        }
    }
    func sleep() {
        sleeping = true
        health.sleep()
        refreshTimer?.cancel()
        rotationTimer?.cancel()
        for task in reads.values { task.cancel() }
    }
    func wake() {
        sleeping = false
        health.wake()
        now = Date()
        startRotation()
        for provider in providers { states[provider]?.lastAttempt = nil }
        refreshAll()
        schedule()
    }
    func accessibilityChanged() {
        startRotation()
        objectWillChange.send()
        statusChanged?()
    }
    func shutdown() async {
        stopping = true
        await health.shutdown()
        refreshTimer?.cancel()
        rotationTimer?.cancel()
        clockTimer?.cancel()
        let tasks = Array(reads.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .normal: .green
        case .unavailable: .secondary
        case .low: .orange
        case .critical: .red
        }
    }
    var label: String {
        switch self {
        case .normal: ""
        case .unavailable: "Unavailable"
        case .low: "Low"
        case .critical: "Very low"
        }
    }
}
