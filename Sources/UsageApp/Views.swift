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

struct StatusContent: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                if let provider = store.current {
                    HStack(spacing: 5) {
                        Text(provider.name).font(.system(size: 12, weight: .medium)).frame(
                            width: 43, alignment: .leading)
                        if store.style == "ring" {
                            ZStack {
                                Circle().stroke(.primary.opacity(0.18), lineWidth: 2.5)
                                Circle().trim(from: 0, to: (store.displayAmount(provider) ?? 0) / 100)
                                    .stroke(
                                        store.severity(provider).color,
                                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                                    ).rotationEffect(.degrees(-90))
                            }.frame(width: 15, height: 15)
                        } else if store.style != "number" {
                            MeterBar(
                                value: store.displayAmount(provider), color: store.severity(provider).color
                            ).frame(width: 20, height: 6)
                        }
                        Text(store.value(provider)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .frame(width: store.style == "number" ? 55 : 32, alignment: .trailing)
                    }.frame(width: 111).id(provider)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)))
                } else {
                    Text("Sparebar").font(.system(size: 12)).frame(width: 111)
                }
            }.frame(width: 111, height: 22).clipped()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(store.warning.color)
                .opacity(store.warning == .normal ? 0 : 1).frame(width: 13)
        }.padding(.horizontal, 7).frame(width: 144, height: 24).accessibilityHidden(true)
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
    let showSettings: () -> Void
    let quit: () -> Void
    var body: some View {
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
                    "Meter style",
                    selection: Binding(get: { store.style }, set: { store.set($0, for: "style") })
                ) {
                    Text("Bar").tag("bar")
                    Text("Gauge").tag("ring")
                    Text("Percentage").tag("number")
                }.pickerStyle(.segmented)
                Toggle(
                    "Show remaining allowance",
                    isOn: Binding(get: { store.showRemaining }, set: { store.set($0, for: "remaining") }))
                Text(
                    "Amber at 20% remaining; red at 10%. Warnings use remaining allowance even when percentages show used."
                ).font(.caption).foregroundStyle(.secondary)
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
