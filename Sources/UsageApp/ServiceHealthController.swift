import Foundation
import SwiftUI
import UsageCore
import UsageProviders

@MainActor final class ServiceHealthController {
    typealias Read = @Sendable (Provider) async throws -> ServiceHealthSnapshot
    private(set) var states = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, ServiceHealthState()) })
    var onChange: (() -> Void)?
    var reading = false {
        didSet { if reading { acknowledge() } }
    }
    private let demo: Bool
    private let read: Read
    private let pause: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable () -> TimeInterval
    private let interval: TimeInterval
    private var providers: [Provider] = []
    private var tasks: [Provider: Task<Void, Never>] = [:]
    private var retired: [UUID: Task<Void, Never>] = [:]
    private var ticker: Task<Void, Never>?
    private var started = false
    private var sleeping = false
    private var presentedSignals: [Provider: Int] = [:]

    init(
        demo: Bool, interval: TimeInterval = 300,
        read: Read? = nil,
        pause: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        jitter: @escaping @Sendable () -> TimeInterval = { .random(in: 0...15) }
    ) {
        self.demo = demo
        self.interval = interval
        let client = ServiceHealthClient()
        self.read = read ?? { try await client.read($0) }
        self.pause = pause
        self.jitter = jitter
        if demo { for provider in Provider.allCases { showDemo(provider, level: .operational) } }
    }

    func start(providers: [Provider]) {
        guard !started else { return }
        started = true
        setProviders(providers)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                if !self.sleeping {
                    for provider in self.providers { self.states[provider]?.remind(at: Date()) }
                    self.onChange?()
                }
            }
        }
    }

    func setProviders(_ providers: [Provider]) {
        self.providers = providers
        for provider in Array(tasks.keys) where !providers.contains(provider) { cancel(provider) }
        guard started, !sleeping, !demo else { return }
        for provider in providers where tasks[provider] == nil { poll(provider) }
    }

    private func poll(_ provider: Provider) {
        let read = self.read, pause = self.pause, jitter = self.jitter
        tasks[provider] = Task { [weak self] in
            do { try await pause(max(0, jitter())) } catch { return }
            while !Task.isCancelled {
                var delay: TimeInterval
                do {
                    let snapshot = try await read(provider)
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.states[provider]?.apply(snapshot, at: Date(), reading: self.reading)
                    self.onChange?()
                    delay = self.interval
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.states[provider]?.fail()
                    self.onChange?()
                    delay = self.states[provider]?.retryDelay(serverDelay: (error as? ServiceHealthError)?.retryAfter) ?? 600
                }
                do { try await pause(delay + max(0, jitter())) } catch { return }
            }
        }
    }

    private func cancel(_ provider: Provider) {
        if let task = tasks.removeValue(forKey: provider) {
            task.cancel()
            let id = UUID()
            retired[id] = task
            Task { [weak self] in
                await task.value
                self?.retired.removeValue(forKey: id)
            }
        }
    }
    func sleep() {
        sleeping = true
        for provider in Array(tasks.keys) { cancel(provider) }
    }
    func wake() {
        sleeping = false
        setProviders(providers)
        onChange?()
    }
    func shutdown() async {
        started = false
        ticker?.cancel()
        for provider in Array(tasks.keys) { cancel(provider) }
        for task in Array(retired.values) { await task.value }
        retired.removeAll()
    }
    private func acknowledge() {
        for provider in providers { states[provider]?.acknowledge() }
        onChange?()
    }
    func level(_ provider: Provider, at date: Date) -> ServiceHealthLevel {
        states[provider]?.level(at: date) ?? .unknown
    }
    func consumeSignal(_ provider: Provider, at date: Date = Date()) -> Bool {
        guard let state = states[provider], let signal = state.signal,
            presentedSignals[provider] != signal.sequence else { return false }
        presentedSignals[provider] = signal.sequence
        return !sleeping && state.level(at: date) != .unknown && date.timeIntervalSince(signal.date) < 60
    }
    func tooltip(_ provider: Provider, at date: Date) -> String {
        let level = level(provider, at: date)
        if level == .unknown { return "\(provider.serviceName) service status is unconfirmed." }
        if level == .operational { return "\(provider.serviceName): no service incidents reported." }
        let detail = states[provider]?.snapshot?.incidents.first?.displayName
            ?? states[provider]?.snapshot?.affected.map(\.displayName).prefix(3).joined(separator: ", ") ?? ""
        return "\(provider.serviceName): \(level.label.lowercased()). \(detail)"
    }
    func showDemo(_ provider: Provider, level: ServiceHealthLevel) {
        guard demo else { return }
        let status: String = switch level {
        case .operational: "operational"
        case .degraded: "degraded_performance"
        case .outage: "major_outage"
        case .unknown: "unrecognized"
        }
        let names = provider == .codex ? ["ChatGPT", "Images", "Codex", "OpenAI API"] : ["Claude.ai", "Claude Code", "Claude API"]
        let components = names.enumerated().map { index, name in
            ServiceComponent(id: "sample-\(index)", name: name, status: index == 1 ? status : "operational")
        }
        states[provider]?.apply(.init(components: components), at: Date(), reading: reading)
        onChange?()
    }
}
