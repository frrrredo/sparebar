import SwiftUI

struct UpdatePanel: View {
    @ObservedObject var updates: UpdateController
    var showDetails: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(updates.title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                if let showDetails, updates.hasUpdate, !updates.releaseNotes.isEmpty {
                    Button(action: showDetails) { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).help("What's new").accessibilityLabel(
                            "Read full update notes")
                }
            }
            if updates.hasUpdate {
                Text(updates.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if updates.busy {
                HStack {
                    if let progress = updates.progress, updates.phase == .downloading {
                        ProgressView(value: progress).accessibilityLabel("Update download")
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel(updates.title)
                    }
                    if updates.canCancel {
                        Spacer()
                        Button("Cancel") { updates.cancel() }.buttonStyle(.borderless)
                    }
                }
            }
            if updates.phase == .available || updates.phase == .ready {
                Button(updates.phase == .ready ? "Restart to Update" : "Update and Restart") {
                    updates.install()
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
                .accessibilityHint("Installs the update and restarts Sparebar")
            } else if updates.phase == .failed {
                Text(updates.message).font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Try Again") { updates.check() }
            } else if updates.phase == .information {
                Button("View Release") { updates.showInformation() }
            }
        }.accessibilityElement(children: .contain)
    }
}
