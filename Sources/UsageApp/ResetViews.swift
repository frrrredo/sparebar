import SwiftUI
import UsageCore

struct SpareSlots {
    let available: Int
    let used: Int
    var filled: Int { min(max(0, available), used > 0 ? 4 : 6) }
    var empty: Int { min(max(0, used), 6 - filled) }
    var total: Int { max(1, filled + empty) }
    var abbreviated: Bool { filled < available || empty < used }
}

struct SpareBattery: View {
    let available: Bool
    var body: some View {
        HStack(spacing: 1) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).strokeBorder(
                    available ? Color.blue : Color.secondary.opacity(0.5), lineWidth: 1.2)
                if available {
                    ZStack {
                        RoundedRectangle(cornerRadius: 2).fill(.blue.opacity(0.18)).padding(3)
                        Image(systemName: "bolt.fill").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.blue)
                    }.transition(
                        .asymmetric(insertion: .opacity, removal: .move(edge: .top).combined(with: .opacity)))
                } else {
                    Image(systemName: "minus").font(.system(size: 8, weight: .medium)).foregroundStyle(
                        .secondary)
                }
            }.frame(width: 32, height: 19)
            RoundedRectangle(cornerRadius: 1).fill(available ? Color.blue : Color.secondary.opacity(0.5))
                .frame(width: 2, height: 7)
        }.frame(width: 35, height: 22)
    }
}

struct SpareReserve: View {
    @ObservedObject var resets: ResetController
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        if let context = resets.context {
            let count = context.snapshot.resetCredits
            let used = resets.displayedUsed
            let slots = SpareSlots(available: count ?? 0, used: used)
            VStack(alignment: .leading, spacing: 7) {
                Divider().padding(.top, 3)
                HStack(spacing: 9) {
                    ForEach(0..<slots.total, id: \.self) { index in
                        SpareBattery(available: index < slots.filled)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                .animation(reducedMotion ? nil : .easeOut(duration: 0.3), value: slots.filled)
                .opacity(context.current ? 1 : 0.6)
                HStack(alignment: .firstTextBaseline) {
                    Text(
                        count.map {
                            $0 == 0
                                ? "No spares available" : "\($0) \($0 == 1 ? "reset" : "resets") available"
                        } ?? "Spares unavailable")
                    Spacer(minLength: 4)
                    if resets.storageReady { Text("\(used) used").foregroundStyle(.secondary) }
                }.font(.system(size: 11)).monospacedDigit()
                if used > 0 {
                    Text("Used in Sparebar on this Mac").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if slots.abbreviated {
                    Text("Some batteries hidden; totals shown above.").font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if count == nil {
                    Text("This Codex account or CLI does not report reserves.").font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if !context.current {
                    Text("Last reported reserve. Refresh to check.").font(.system(size: 10)).foregroundStyle(
                        .secondary)
                } else if let expiry = context.snapshot.resetDetails.compactMap(\.expiresAt).filter({
                    $0 > Date()
                }).min(), (count ?? 0) > 0 {
                    Text("Reported expiry: \(expiry.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .help("The provider may return only part of the reserve details.")
                }
                if resets.busyInCurrentContext {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Using your spare...")
                    }
                    .font(.system(size: 11)).accessibilityLabel("Using your spare. Please wait.")
                } else if resets.busy {
                    Text("Finishing a reset for the previous connection...").font(.system(size: 11))
                } else {
                    if let message = resets.message {
                        Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                    if resets.record.pending != nil {
                        Button("Review pending reset") { resets.ask(retry: true) }
                            .font(.system(size: 11)).disabled(!resets.canRetry)
                            .help("Retry the saved request, using the same request ID.")
                    }
                }
            }
        }
    }
}

struct SparePrompt: View {
    @ObservedObject var resets: ResetController
    var body: some View {
        if resets.canOffer {
            VStack(alignment: .leading, spacing: 7) {
                Text("Running low. You've got backup.").font(.system(size: 12, weight: .medium))
                HStack {
                    Text("Codex has \(Int((resets.context?.meter?.remaining ?? 0).rounded()))% left")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Use a spare") { resets.ask() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }.padding(10).background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 7).padding(.bottom, 10)
        }
    }
}

struct SpareConfirmation: View {
    @ObservedObject var resets: ResetController
    let context: ResetContext
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SpareBattery(available: true)
                Spacer()
                Text("Codex").foregroundStyle(.secondary)
            }
            Text(resets.retryConfirmation ? "Confirm your pending reset" : "Use a spare battery?")
                .font(.system(size: 17, weight: .semibold))
            Text(context.snapshot.accountLabel ?? "Signed-in Codex account")
                .font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                resets.retryConfirmation
                    ? "This retries your saved request. If it already succeeded, another spare will not be used. If it did not, this can use one reset."
                    : "Use one Codex usage reset from your reserve of \(context.snapshot.resetCredits ?? 0)."
            )
            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text(
                "OpenAI chooses an eligible reset and the limits it restores. The change applies to this account on all your devices."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let detail = context.snapshot.resetDetails.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.title).fontWeight(.medium)
                    if let description = detail.description, !description.isEmpty { Text(description) }
                    Text(
                        detail.expiresAt.map {
                            "Expires \($0.formatted(date: .abbreviated, time: .shortened))"
                        } ?? "Expiry not provided")
                    Text("Reported reserve detail; OpenAI selects which reset to use.").foregroundStyle(
                        .secondary)
                }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Reset expiry details are not provided by this account.").font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { resets.cancelConfirmation() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(resets.retryConfirmation ? "Retry saved request" : "Use 1 reset") { resets.confirm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(resets.retryConfirmation ? !resets.canRetry : !resets.canOffer)
            }.padding(.top, 4)
        }.padding(17).frame(width: 332).background(Color(nsColor: .windowBackgroundColor))
    }
}
