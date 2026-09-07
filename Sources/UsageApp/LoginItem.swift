import ServiceManagement
import SwiftUI

@MainActor final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var changing = false
    @Published private(set) var error: String?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () async throws -> Void

    init(
        readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () async throws -> Void = { try await SMAppService.mainApp.unregister() }
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }
    var enabled: Bool { status == .enabled || status == .requiresApproval }
    func refresh() { status = readStatus() }
    func setEnabled(_ enabled: Bool) async {
        guard !changing else { return }
        changing = true
        error = nil
        defer {
            refresh()
            changing = false
        }
        do {
            if enabled { try register() } else { try await unregister() }
        } catch {
            self.error = "Could not change launch at login. Move Sparebar to Applications and try again."
        }
    }
}
