import AppKit
import ServiceManagement
import SwiftUI
import UsageCore

struct MeterBar: View {
    let value: Double?
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(color).frame(
                    width: proxy.size.width * CGFloat(max(0, min(100, value ?? 0))) / 100)
            }
        }.accessibilityHidden(true)
    }
}

@MainActor struct StatusLayout {
    static let markerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    let style: String
    var showPercentage = true
    var differentiateWithoutColor = false
    var hasProvider = true
    var readings = ["100%"]
    var markerWidth: CGFloat {
        differentiateWithoutColor
            ? ceil(("Cdx" as NSString).size(withAttributes: [.font: Self.markerFont]).width) + 4 : 0
    }
    var valueWidth: CGFloat {
        showPercentage
            ? ceil(
                readings.map { ($0 as NSString).size(withAttributes: [.font: Self.valueFont]).width }.max()
                    ?? 0)
            : 0
    }
    var meterWidth: CGFloat { style == "number" ? 0 : style == "ring" ? 14 : 19 }
    var iconWidth: CGFloat { 29 }
    var width: CGFloat {
        guard hasProvider else {
            return ceil(("Sparebar" as NSString).size(withAttributes: [.font: Self.valueFont]).width)
        }
        return markerWidth + valueWidth + (showPercentage ? 3 : 0) + meterWidth + iconWidth
    }
}

struct StatusAgent: View {
    let color: Color
    let eyeColor: Color
    let amount: Double?
    var health: ServiceHealthLevel = .operational
    var healthSignal: ServiceHealthSignal?
    var reducedMotion = false
    var consumeHealthSignal: () -> Bool = { true }
    private let bodyHeight: CGFloat = 13 * 1.15
    private var battery: some View {
        Image(systemName: "battery.0percent")
            .resizable().symbolRenderingMode(.monochrome)
            .font(.system(size: 14, weight: .light))
            .frame(width: 26, height: bodyHeight)
    }
    private var terminal: some View {
        battery.frame(width: 2.5, height: bodyHeight, alignment: .trailing).clipped()
    }
    private var eyes: some View {
        ServiceHealthEyes(level: health, color: eyeColor, signal: healthSignal, reducedMotion: reducedMotion,
                          consumeSignal: consumeHealthSignal)
            .frame(width: 19, height: bodyHeight - 4)
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color)
                eyes
            }.frame(width: 19, height: bodyHeight - 4).offset(x: 5, y: 2)
            battery.offset(x: 3)
            battery.scaleEffect(x: -1, y: 1)
                .mask(alignment: .leading) { Rectangle().frame(width: 4) }
            terminal.rotationEffect(.degrees(-90))
                .frame(width: bodyHeight, height: 2.5).offset(x: (29 - bodyHeight) / 2, y: -2.5)
        }
        .foregroundStyle(Color.primary.opacity(0.6))
        .frame(width: 29, height: bodyHeight, alignment: .topLeading)
    }
}

struct StatusContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updates: UpdateController
    @Environment(\.colorScheme) private var colorScheme
    private var layout: StatusLayout {
        StatusLayout(
            style: store.style, showPercentage: store.showPercentage,
            differentiateWithoutColor: store.differentiateWithoutColor,
            hasProvider: store.current != nil, readings: store.providers.map(store.value))
    }
    private var severity: Severity { store.current.map(store.severity) ?? .unavailable }
    private var foreground: Color {
        switch severity {
        case .normal: .primary
        case .unavailable: .secondary
        case .low:
            colorScheme == .dark
                ? Color(red: 0.98, green: 0.75, blue: 0.33)
                : Color(red: 0.62, green: 0.35, blue: 0.04)
        case .critical:
            colorScheme == .dark
                ? Color(red: 1, green: 0.50, blue: 0.45)
                : Color(red: 0.76, green: 0.18, blue: 0.19)
        }
    }
    private func markerColor(_ provider: Provider) -> Color {
        if provider == .codex {
            return colorScheme == .dark
                ? Color(red: 0.40, green: 0.68, blue: 1)
                : Color(red: 0.10, green: 0.36, blue: 0.70)
        }
        return colorScheme == .dark
            ? Color(red: 0.94, green: 0.58, blue: 0.40)
            : Color(red: 0.66, green: 0.30, blue: 0.17)
    }
    var body: some View {
        ZStack {
            if let provider = store.current {
                HStack(spacing: 0) {
                    if store.differentiateWithoutColor {
                        Text(provider == .codex ? "Cdx" : "Cld")
                            .font(Font(StatusLayout.markerFont)).foregroundStyle(markerColor(provider))
                            .frame(width: layout.markerWidth, alignment: .leading)
                            .transaction { $0.animation = nil }
                    }
                    HStack(spacing: 3) {
                        if store.showPercentage {
                            Text(store.value(provider))
                                .underline(store.differentiateWithoutColor && severity >= .low)
                                .frame(width: layout.valueWidth, alignment: .trailing)
                                .contentTransition(.identity).transaction { $0.animation = nil }
                        }
                        if store.style == "ring" {
                            ZStack {
                                Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 2)
                                Circle().inset(by: 1).trim(
                                    from: 0, to: (store.displayAmount(provider) ?? 0) / 100
                                )
                                .stroke(
                                    foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round)
                                ).rotationEffect(.degrees(-90))
                            }.frame(width: 11, height: 11).transaction { $0.animation = nil }
                        } else if store.style != "number" {
                            MeterBar(value: store.displayAmount(provider), color: foreground)
                                .frame(width: 16, height: 4).transaction { $0.animation = nil }
                        }
                        ZStack {
                            StatusAgent(
                                color: markerColor(provider), eyeColor: provider == .codex ? .white : .black,
                                amount: store.displayAmount(provider),
                                health: store.health.level(provider, at: store.now),
                                healthSignal: store.health.states[provider]?.signal,
                                reducedMotion: store.reducedMotion,
                                consumeHealthSignal: { store.health.consumeSignal(provider) }
                            )
                            .id(provider)
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)))
                        }.frame(width: layout.iconWidth, height: 22).clipped()
                    }
                    .frame(height: 18)
                }
                .frame(width: layout.width, alignment: .leading)
            } else {
                Text("Sparebar")
            }
        }
        .font(Font(StatusLayout.valueFont)).foregroundStyle(foreground)
        .frame(width: layout.width, height: 22).clipped()
        .overlay(alignment: .topTrailing) {
            if updates.hasUpdate {
                Circle().fill(.orange)
                    .overlay { Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1) }
                    .frame(width: 5, height: 5).padding(.top, 1).padding(.trailing, 1)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(store.reducedMotion ? nil : .easeOut(duration: 0.2), value: updates.hasUpdate)
        .frame(height: 24).accessibilityHidden(true)
    }
}

struct AllowanceRow: View {
    @ObservedObject var store: UsageStore
    let provider: Provider
    var body: some View {
        let state = store.states[provider] ?? .init()
        let meter = store.meter(provider)
        let valid = store.valid(provider)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(provider.name).fontWeight(.medium)
                Spacer()
                if state.checking {
                    ProgressView().controlSize(.mini).accessibilityLabel("Checking \(provider.name)")
                } else if store.severity(provider) != .normal {
                    Text(store.severity(provider).label).font(.system(size: 11)).foregroundStyle(
                        store.severity(provider).color)
                }
                Text(store.value(provider)).font(.system(size: 14, weight: .medium)).monospacedDigit().frame(
                    minWidth: 32, alignment: .trailing)
            }
            if let snapshot = state.snapshot {
                Picker(
                    "\(provider.name) allowance",
                    selection: Binding(
                        get: { store.selected(provider) },
                        set: { store.set($0, for: "meter.\(provider.rawValue)") })
                ) {
                    Text(snapshot.preferred.map { "Automatic (\($0.label))" } ?? "Automatic").tag("")
                    ForEach(snapshot.allowances) { allowance in Text(allowance.label).tag(allowance.id) }
                    if !store.selected(provider).isEmpty && meter == nil {
                        Text("Previously selected (unavailable)").tag(store.selected(provider))
                    }
                }.labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize(
                    horizontal: false, vertical: true)
            }
            MeterBar(value: store.displayAmount(provider), color: store.severity(provider).color).frame(
                height: 5)
            HStack(alignment: .top) {
                Text(valid ? resetText(meter?.resetsAt) : store.detail(provider)).fixedSize(
                    horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if store.current == provider { Text("In menu bar").fixedSize() }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            if !valid, let meter {
                Text("Last reading: \(Int(meter.remaining.rounded()))% remaining").font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !state.checking, state.snapshot == nil {
                if state.issue == .missingCLI {
                    Link("Set up \(provider.cliName)", destination: provider.setupURL).font(.system(size: 11))
                } else if state.issue == .signIn || state.issue == .subscriptionRequired {
                    Link("Sign in with \(provider.cliName)", destination: provider.setupURL).font(
                        .system(size: 11))
                }
            }
            if let checked = state.snapshot?.checkedAt {
                Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(10).background(
            store.current == provider ? Color.primary.opacity(0.055) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            valid
                ? "\(provider.name), \(meter?.label ?? "allowance"), \(store.value(provider)) \(store.showRemaining ? "remaining" : "used")"
                : "\(provider.name), allowance unavailable")
    }
    private func resetText(_ reset: Date?) -> String {
        guard let reset else { return "Reset not provided" }
        let seconds = max(0, Int(reset.timeIntervalSince(store.now)))
        if seconds >= 86_400 { return "Resets in \(seconds / 86_400)d \((seconds % 86_400) / 3_600)h" }
        if seconds >= 3_600 { return "Resets in \(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        return "Resets in \(max(1, seconds / 60))m"
    }
}

struct PopoverContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updates: UpdateController
    let showSettings: () -> Void
    let quit: () -> Void
    @State private var showingNotes = false
    var body: some View {
        Group {
            if showingNotes {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            showingNotes = false
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }.buttonStyle(.borderless)
                        Spacer()
                        Text("What's new").fontWeight(.medium)
                    }
                    ScrollView {
                        Text(updates.releaseNotes).font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(height: 210)
                    UpdatePanel(updates: updates)
                }.padding(15).frame(width: 332).background(Color(nsColor: .windowBackgroundColor))
            } else {
                allowances
            }
        }
    }
    private var allowances: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "chart.bar.fill").font(.system(size: 16))
                Text("Sparebar").font(.system(size: 14, weight: .medium))
                Spacer()
                Button {
                    store.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("Refresh usage").accessibilityLabel("Refresh usage").disabled(
                    store.allChecking || store.demo)
                Button(action: showSettings) { Image(systemName: "slider.horizontal.3") }.help("Settings")
                    .accessibilityLabel("Settings")
            }.buttonStyle(.borderless).padding(.horizontal, 15).padding(.top, 16).padding(.bottom, 13)
            if updates.visible {
                UpdatePanel(updates: updates, showDetails: { showingNotes = true })
                    .padding(.horizontal, 15).padding(.bottom, 13)
                Divider().padding(.bottom, 10)
            }
            if !store.providers.isEmpty {
                ServiceHealthPanel(store: store)
                Divider().padding(.bottom, 10)
            }
            HStack {
                Text("Allowance")
                Spacer()
                Text(store.showRemaining ? "Remaining" : "Used")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 17).padding(.bottom, 4)
            if store.providers.isEmpty {
                VStack(spacing: 10) {
                    Text("Choose a tool to monitor")
                    Button("Open Settings", action: showSettings)
                }.padding(20)
            }
            ForEach(store.providers) { provider in
                AllowanceRow(store: store, provider: provider).padding(.horizontal, 7).padding(.vertical, 2)
            }
            HStack {
                Text(store.warningText)
                Spacer()
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 17).padding(
                .vertical, 12)
            if store.demo { Text("Demo data").font(.caption).foregroundStyle(.secondary).padding(.bottom, 8) }
            Divider()
            HStack(spacing: 14) {
                Text(store.rotationLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    store.set(!store.rotating, for: "rotation")
                } label: {
                    Image(systemName: store.rotating ? "pause" : "play")
                }
                .accessibilityLabel(store.rotating ? "Pause rotation" : "Resume rotation").disabled(
                    store.providers.count < 2 || store.reducedMotion)
                Button {
                    store.advance()
                } label: {
                    Image(systemName: "chevron.right")
                }.accessibilityLabel("Show next tool").disabled(store.providers.count < 2)
                Menu {
                    Toggle(
                        "Show Percentage",
                        isOn: Binding(
                            get: { store.showPercentage }, set: { store.set($0, for: "showPercentage") }))
                    Divider()
                    Button("Check for Updates...") { updates.check() }.disabled(updates.busy || store.demo)
                    Button("About Sparebar") { NSApp.orderFrontStandardAboutPanel() }
                    Divider()
                    Button("Quit Sparebar", action: quit).keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis")
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More options")
            }.buttonStyle(.borderless).padding(.horizontal, 15).padding(.vertical, 12)
        }.frame(width: 332).background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ConnectionEditor: View {
    @ObservedObject var store: UsageStore
    let provider: Provider
    @State private var path = ""
    @State private var configRoot = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Toggle(
                    provider.cliName,
                    isOn: Binding(
                        get: { store.enabled(provider) }, set: { store.setEnabled($0, provider: provider) }))
                Spacer()
                Text(store.detail(provider)).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Connection details") {
                VStack(alignment: .leading, spacing: 8) {
                    if let version = store.states[provider]?.version {
                        Text("Version \(version)").font(.caption)
                    }
                    if let detected = store.states[provider]?.executable {
                        Text(detected).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .lineLimit(2)
                    }
                    HStack {
                        TextField("Automatic executable detection", text: $path)
                        Button("Locate...") { locate(folder: false) }
                    }
                    HStack {
                        TextField("Default CLI configuration folder", text: $configRoot)
                        Button("Choose...") { locate(folder: true) }
                    }
                    HStack {
                        Button("Apply and refresh") {
                            store.applyConnection(provider, path: path, root: configRoot)
                        }
                        Spacer()
                        Link("Tool setup", destination: provider.setupURL)
                    }
                    Text(
                        provider == .claude
                            ? "Claude may return cached readings. Checked time means the CLI responded; it is not a provider observation time."
                            : "Reads your signed-in Codex account without starting a conversation."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if let count = store.states[provider]?.snapshot?.resetCredits {
                        Text("Available reset credits: \(count)").font(.caption)
                    }
                }.padding(.top, 8)
            }
        }.onAppear {
            path = store.preference("path.\(provider.rawValue)")
            configRoot = store.preference("root.\(provider.rawValue)")
        }
    }
    private func locate(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        panel.title =
            folder
            ? "Choose the CLI configuration folder" : "Locate the official \(provider.cliName) executable"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            if folder { configRoot = url.path } else { path = url.path }
        }
    }
}

struct SettingsContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updates: UpdateController
    @StateObject private var loginItem = LoginItem()
    var body: some View {
        Form {
            Section {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { loginItem.enabled },
                        set: { enabled in Task { await loginItem.setEnabled(enabled) } })
                )
                .disabled(loginItem.changing || store.demo)
                if loginItem.status == .requiresApproval {
                    HStack {
                        Text("Allow Sparebar in Login Items to finish enabling it.").font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = loginItem.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Menu bar") {
                Toggle(
                    "Rotate connected tools",
                    isOn: Binding(get: { store.rotating }, set: { store.set($0, for: "rotation") }))
                Picker(
                    "Show each tool for",
                    selection: Binding(get: { store.interval }, set: { store.set($0, for: "interval") })
                ) {
                    ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) seconds").tag($0) }
                }.disabled(!store.rotating)
                Picker(
                    "Extra meter",
                    selection: Binding(get: { store.style }, set: { store.set($0, for: "style") })
                ) {
                    Text("Bar").tag("bar")
                    Text("Gauge").tag("ring")
                    Text("None").tag("number")
                }.pickerStyle(.segmented)
                Toggle(
                    "Show Percentage",
                    isOn: Binding(
                        get: { store.showPercentage }, set: { store.set($0, for: "showPercentage") }))
                Toggle(
                    "Show remaining allowance",
                    isOn: Binding(get: { store.showRemaining }, set: { store.set($0, for: "remaining") }))
                Text(
                    "Blue is Codex; orange is Claude. The eyes show service health; the percentage and extra meter show allowance. Hover for details. The reading turns amber at 20% remaining and red at 10%, even when percentages show used."
                ).font(.caption).foregroundStyle(.secondary)
            }
            Section("Service health") {
                ServiceHealthPreferences(store: store)
                ServiceHealthExplanation()
            }
            Section("Updates") {
                Toggle(
                    "Automatic updates",
                    isOn: Binding(
                        get: { updates.automaticUpdates }, set: { updates.setAutomaticUpdates($0) }
                    )
                ).disabled(store.demo)
                Text(
                    "Downloads updates in the background and installs them when you quit. Sparebar won't restart on its own."
                )
                .font(.caption).foregroundStyle(.secondary)
                if !updates.automaticUpdates && updates.phase == .ready {
                    Text("The prepared update will still install when you quit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Checks once a day, even when automatic updates are off.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updates.check() }.disabled(updates.busy || store.demo)
                }
                if updates.phase == .failed {
                    Text(updates.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Connections") {
                ForEach(Provider.allCases) { ConnectionEditor(store: store, provider: $0) }
            }
            Section {
                HStack {
                    Text("Usage refreshes every 5 minutes.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh now") { store.refreshAll() }.disabled(store.allChecking || store.demo)
                }
                Text(
                    "Authentication stays in your official tools. Sparebar stores preferences, not provider credentials or usage history."
                ).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 510, height: 650)
            .onAppear { loginItem.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
                _ in loginItem.refresh()
            }
    }
}
