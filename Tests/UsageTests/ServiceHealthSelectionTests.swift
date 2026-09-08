import Foundation
import Testing
import UsageCore
@testable import UsageApp
@testable import UsageProviders

private func serviceSnapshot(_ provider: Provider, bad: String? = nil, status: String = "major_outage",
                             incidents: [ServiceIncident] = []) -> ServiceHealthSnapshot {
    let components = WatchedService.catalog(for: provider).flatMap { service in
        service.componentIDs.sorted().map {
            ServiceComponent(id: $0, name: service.name, status: service.id == bad ? status : "operational")
        }
    }
    return .init(components: components, incidents: incidents, indicator: bad == nil ? "none" : "major",
                 groups: WatchedService.catalog(for: provider))
}

struct ServiceHealthSelectionTests {
    @Test func unrelatedGovernmentOutagesAndRollupsDoNotAffectSelectedServices() {
        for provider in Provider.allCases {
            let government = provider == .codex ? "fedramp" : "government"
            let ids = WatchedService.catalog(for: provider).first { $0.id == government }!.componentIDs
            let incident = ServiceIncident(id: "government", name: "Sample government incident", status: "investigating", impact: "major", componentIDs: ids)
            let raw = serviceSnapshot(provider, bad: government, incidents: [incident])
            let filtered = raw.filtered(for: provider, services: WatchedService.defaults(for: provider))
            #expect(raw.level == .outage)
            #expect(filtered.level == .operational)
            #expect(filtered.incidents.isEmpty)
            #expect(filtered.affected.isEmpty)
            #expect(raw.filtered(for: provider, services: [government]).level == .outage)
        }
    }

    @Test func globalIncidentSeverityDoesNotLeakFromExcludedComponents() {
        let chat = "rwppv331jlwc", government = "0scnb50nvy53"
        let snapshot = ServiceHealthSnapshot(components: [
            .init(id: chat, name: "claude.ai", status: "degraded_performance"),
            .init(id: government, name: "Government", status: "major_outage"),
        ], incidents: [.init(id: "mixed", name: "Sample multi-service incident", status: "identified", impact: "critical", componentIDs: [chat, government])])
        #expect(snapshot.filtered(for: .claude, services: ["chat"]).level == .degraded)
    }

    @Test func fullySelectedIncidentRetainsItsReportedSeverity() {
        let incident = ServiceIncident(id: "chat", name: "Sample chat outage", status: "investigating",
            impact: "major", componentIDs: ["rwppv331jlwc"])
        // Incident publication can precede the component status change.
        let raw = serviceSnapshot(.claude, incidents: [incident])
        #expect(raw.filtered(for: .claude, services: ["chat"]).level == .outage)
    }

    @Test func missingScopeAndIncompleteCoverageRemainUnconfirmed() {
        let incident = ServiceIncident(id: "unclear", name: "Sample service report", status: "monitoring", impact: "major")
        let raw = serviceSnapshot(.claude, incidents: [incident])
        let filtered = raw.filtered(for: .claude, services: ["chat", "code"])
        #expect(filtered.level == .unknown)
        #expect(filtered.unscopedIncidents.count == 1)
        #expect(filtered.incidents.isEmpty)
        let missing = ServiceHealthSnapshot(components: [.init(id: "rwppv331jlwc", name: "claude.ai", status: "operational")])
        #expect(missing.filtered(for: .claude, services: ["chat", "code"]).scopeIncomplete)
        #expect(missing.filtered(for: .claude, services: ["chat", "code"]).level == .unknown)
    }

    @Test func selectionEditsPreserveFreshnessFailuresAndDoNotCelebrateRecovery() {
        let date = Date(timeIntervalSince1970: 1000)
        var state = ServiceHealthState()
        state.apply(serviceSnapshot(.claude, bad: "code"), at: date)
        state.fail()
        let raw = serviceSnapshot(.claude, bad: "code")
        state.reproject(raw.filtered(for: .claude, services: ["chat"]))
        #expect(state.checkedAt == date)
        #expect(state.failed && state.failures == 1)
        #expect(state.signal == nil && state.nextReminder == nil)
        #expect(state.level(at: date) == .unknown)
        state.apply(raw.filtered(for: .claude, services: ["chat"]), at: date.addingTimeInterval(300))
        #expect(state.level(at: date.addingTimeInterval(301)) == .operational)
        #expect(state.signal == nil)
    }

    @Test func officialIncidentMembershipIsDecodedWithoutTitleMatching() throws {
        let data = Data(#"{"components":[{"id":"rwppv331jlwc","name":"claude.ai","status":"operational"},{"id":"0scnb50nvy53","name":"Government","status":"major_outage"}],"incidents":[{"id":"one","name":"Claude chat issue in title only","status":"investigating","impact":"major","components":[{"id":"0scnb50nvy53"}]}]}"#.utf8)
        let raw = try ServiceHealthSnapshot(data: data)
        #expect(raw.filtered(for: .claude, services: ["chat"]).level == .operational)
    }
}

@MainActor struct ServiceHealthPreferenceTests {
    @Test func defaultsAndExplicitEmptySelectionsPersistIndependently() {
        let name = "Sparebar-health-preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = ServiceHealthController(demo: false, defaults: defaults)
        #expect(first.selected(.codex) == ["chatgpt", "codex"])
        #expect(first.selected(.claude) == ["chat", "code"])
        first.select("chatgpt", for: .codex, enabled: false)
        first.select("codex", for: .codex, enabled: false)
        first.select("cowork", for: .claude, enabled: true)
        let second = ServiceHealthController(demo: false, defaults: defaults)
        #expect(!second.monitoring(.codex))
        #expect(second.selectionLabel(.codex) == "No services selected")
        #expect(second.selected(.claude) == ["chat", "code", "cowork"])
    }

    @Test func demoFilteringUsesRawDataWithoutARequestOrRecoverySignal() async {
        let controller = ServiceHealthController(demo: true)
        controller.showDemo(.claude, level: .outage)
        let checked = controller.states[.claude]?.checkedAt
        controller.select("code", for: .claude, enabled: false)
        #expect(controller.level(.claude, at: Date()) == .operational)
        #expect(controller.states[.claude]?.signal == nil)
        #expect(controller.states[.claude]?.checkedAt == checked)
        controller.select("code", for: .claude, enabled: true)
        #expect(controller.level(.claude, at: Date()) == .outage)
        #expect(controller.states[.claude]?.signal == nil)
        await controller.shutdown()
    }
}

struct OpenAIServiceHealthTests {
    private func data(status: String = "full_outage", groupMember: String = "chat") throws -> Data {
        let summary: [String: Any] = [
            "id": "01JMDK9XYNY6RXSED6SDWW50WY",
            "components": [["id": "chat", "name": "Sample chat"], ["id": "gov", "name": "Sample government"]],
            "affected_components": [["component_id": "gov", "status": status]],
            "ongoing_incidents": [["id": "incident", "name": "Sample government incident", "status": "investigating",
                "affected_components": [["component_id": "gov", "status": status]], "component_impacts": []]],
            "structure": ["items": [["group": ["id": "01K5H8S53SY1KMS4GQMNMZXTR1", "name": "ChatGPT", "components": [["component_id": groupMember]]]]]],
        ]
        return try JSONSerialization.data(withJSONObject: ["summary": summary])
    }
    @Test func nativeFeedRetainsGroupMembershipAndIncidentScope() throws {
        let raw = try OpenAIServiceHealth.decode(data())
        #expect(raw.level == .outage)
        #expect(raw.groups.first?.id == "chatgpt")
        #expect(raw.filtered(for: .codex, services: ["chatgpt"]).level == .operational)
        #expect(raw.incidents.first?.componentIDs == ["gov"])
    }
    @Test func missingStructureAndUnknownComponentReferencesAreRejected() throws {
        #expect(throws: (any Error).self) { try OpenAIServiceHealth.decode(data(groupMember: "missing")) }
        #expect(throws: (any Error).self) { try OpenAIServiceHealth.decode(Data(#"{"summary":{"components":[]}}"#.utf8)) }
    }
    @Test func missingSelectedGroupDoesNotFallBackToOldMembership() throws {
        let raw = try OpenAIServiceHealth.decode(data())
        let filtered = raw.filtered(for: .codex, services: ["chatgpt", "codex"])
        #expect(filtered.level == .unknown)
        #expect(filtered.scopeIncomplete)
    }
}
