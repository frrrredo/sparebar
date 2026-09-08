import SwiftUI
import UsageCore

// Service state changes the eyes; the full face identifies the provider.
// Numeric allowance and optional meters remain independent of service reports.
private struct ServiceEye: Shape {
    let level: ServiceHealthLevel
    let happy: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        if happy {
            path.move(to: CGPoint(x: rect.minX + 0.65, y: rect.midY + 1.1))
            path.addCurve(
                to: CGPoint(x: rect.maxX - 0.65, y: rect.midY + 1.1),
                control1: CGPoint(x: rect.minX + 0.65, y: rect.midY - 2.7),
                control2: CGPoint(x: rect.maxX - 0.65, y: rect.midY - 2.7))
            return path.strokedPath(.init(lineWidth: 1.3, lineCap: .butt))
        }
        switch level {
        case .operational:
            path.addRect(rect)
        case .degraded, .unknown:
            let height = level == .degraded ? 2.4225 : 2.85
            path.addRect(CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
        case .outage:
            let inset: CGFloat = 0.33
            path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
            path.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
            path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
            return path.strokedPath(.init(lineWidth: 2.1375, lineCap: .butt))
        }
        return path
    }
}

struct ServiceHealthEyes: View {
    let level: ServiceHealthLevel
    let color: Color
    let signal: ServiceHealthSignal?
    let reducedMotion: Bool
    var consumeSignal: () -> Bool = { true }
    @State private var happy = false
    @State private var openness = 1.0
    private struct MotionKey: Equatable {
        let sequence: Int?
        let reduced: Bool
        let level: ServiceHealthLevel
    }
    var body: some View {
        let size: CGFloat = level == .operational ? 5.13 : 5.7
        HStack(spacing: 2) {
            ForEach(0..<2) { _ in
                ServiceEye(level: level, happy: happy && level == .operational)
                    .fill(level == .unknown ? color.opacity(0.5) : color)
                    .frame(width: size, height: size)
            }
        }
        .scaleEffect(x: 1, y: openness)
        .opacity(0.65 + 0.35 * openness)
        .task(id: MotionKey(sequence: signal?.sequence, reduced: reducedMotion, level: level)) {
            happy = false
            openness = 1
            guard let signal, consumeSignal(), !reducedMotion,
                level.hasIncident || (level == .operational && signal.kind == .recovery)
            else { return }
            happy = signal.kind == .recovery
            defer { happy = false; openness = 1 }
            do {
                if happy { try await Task.sleep(for: .milliseconds(500)) }
                withAnimation(.easeOut(duration: 0.18)) { openness = 0.45 }
                try await Task.sleep(for: .milliseconds(180))
                withAnimation(.easeOut(duration: 0.32)) { openness = 1 }
                try await Task.sleep(for: .milliseconds(happy ? 1120 : 320))
            } catch { return }
        }
        .accessibilityHidden(true)
    }
}

struct ServiceHealthExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Checks official OpenAI and Claude status pages for enabled tools about every five minutes while your Mac is awake.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                legend(.operational, label: "Normal")
                legend(.degraded, label: "Degraded")
                legend(.outage, label: "Outage")
                legend(.unknown, label: "Unconfirmed")
            }
            Text("Open the panel for affected services and official details. Unread outages gently remind every ten minutes; happy eyes briefly mark recovery. Reduce Motion keeps the eyes still.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.caption)
    }
    private func legend(_ level: ServiceHealthLevel, label: String) -> some View {
        VStack(spacing: 5) {
            StatusAgent(color: Color(red: 0.94, green: 0.58, blue: 0.40), eyeColor: .black,
                        amount: nil, health: level, reducedMotion: true)
                .accessibilityHidden(true)
            Text(label)
        }.frame(maxWidth: .infinity)
    }
}

struct ServiceHealthPanel: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(store.providers) { provider in
                let state = store.health.states[provider] ?? .init()
                let level = state.level(at: store.now)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: symbol(level)).foregroundStyle(color(level)).accessibilityHidden(true)
                        Text("\(provider.serviceName): \(headline(level))").fontWeight(.medium)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Link(destination: provider.statusURL) { Image(systemName: "arrow.up.right") }
                            .help("Official \(provider.serviceName) status page")
                            .accessibilityLabel("Open official \(provider.serviceName) status page")
                    }
                    if level == .unknown {
                        Text(state.checkedAt == nil ? "Waiting for an official status check." : "The latest status could not be confirmed.")
                            .foregroundStyle(.secondary)
                    } else if level.hasIncident, let snapshot = state.snapshot {
                        if let incident = snapshot.incidents.first {
                            Text(incident.displayName).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(snapshot.affected.prefix(3))) { component in
                            HStack(alignment: .firstTextBaseline) {
                                Text(component.displayName).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text(component.label).foregroundStyle(color(component.level))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        let more = max(0, snapshot.affected.count - 3)
                        if more > 0 || snapshot.incidents.count > 1 {
                            Link("More details on the status page", destination: provider.statusURL)
                        }
                        if snapshot.affected.isEmpty && snapshot.incidents.isEmpty {
                            Text("The provider reports a service disruption. See its status page for details.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let checked = state.checkedAt {
                        Text("\(level == .unknown ? "Last successful check" : "Checked") \(checked.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .contain)
            }
            if store.demo, let provider = store.current {
                HStack {
                    Picker("Sample status", selection: Binding(
                        get: { store.health.level(provider, at: store.now).rawValue },
                        set: { store.health.showDemo(provider, level: ServiceHealthLevel(rawValue: $0) ?? .unknown) }
                    )) {
                        Text("Operational").tag(ServiceHealthLevel.operational.rawValue)
                        Text("Degraded").tag(ServiceHealthLevel.degraded.rawValue)
                        Text("Outage").tag(ServiceHealthLevel.outage.rawValue)
                        Text("Unknown").tag(ServiceHealthLevel.unknown.rawValue)
                    }.labelsHidden().controlSize(.small)
                    Button("Recovery") {
                        store.health.showDemo(provider, level: .outage)
                        store.health.showDemo(provider, level: .operational)
                    }.controlSize(.small)
                }
            }
        }.font(.system(size: 12)).padding(.horizontal, 15).padding(.bottom, 12)
    }
    private func headline(_ level: ServiceHealthLevel) -> String {
        switch level {
        case .operational: "no incidents reported"
        case .degraded, .outage: "service incident reported"
        case .unknown: "service status unavailable"
        }
    }
    private func symbol(_ level: ServiceHealthLevel) -> String {
        switch level {
        case .operational: "checkmark.circle"
        case .degraded, .outage: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
    }
    private func color(_ level: ServiceHealthLevel) -> Color {
        switch level {
        case .operational: .green
        case .degraded: .orange
        case .outage: .red
        case .unknown: .secondary
        }
    }
}
