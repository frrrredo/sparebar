import ServiceManagement
import Testing

@testable import UsageApp

@MainActor struct LoginItemTests {
    @Test func noRegistrationUntilRequestedAndHonorsExternalChanges() {
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        let item = LoginItem(readStatus: { status }, register: { registrations += 1 }, unregister: {})
        #expect(!item.enabled)
        #expect(registrations == 0)
        status = .enabled
        item.refresh()
        #expect(item.enabled)
        status = .notRegistered
        item.refresh()
        #expect(!item.enabled)
    }
    @Test func approvalAndDisableReflectSystemState() async {
        var status = SMAppService.Status.notRegistered
        let item = LoginItem(
            readStatus: { status }, register: { status = .requiresApproval },
            unregister: { status = .notRegistered })
        await item.setEnabled(true)
        #expect(item.enabled)
        #expect(item.status == .requiresApproval)
        await item.setEnabled(false)
        #expect(!item.enabled)
        #expect(item.error == nil)
    }
    @Test func failedRegistrationDoesNotPretendEnabledOrExposeError() async {
        struct Failure: Error {}
        let item = LoginItem(readStatus: { .notRegistered }, register: { throw Failure() }, unregister: {})
        await item.setEnabled(true)
        #expect(!item.enabled)
        #expect(item.error != nil)
        #expect(!item.changing)
    }
}
