import Foundation
import UsageCore

// Decode the same public JSON used by status.openai.com. Its compatibility
// summary omits components and product membership; the native feed includes both.
enum OpenAIServiceHealth {
    private struct Document: Decodable { let summary: Summary }
    private struct Summary: Decodable {
        let id: String
        let components: [Component]
        let affected_components: [Impact]
        let ongoing_incidents: [Incident]
        let structure: Structure
    }
    private struct Component: Decodable { let id: String; let name: String }
    private struct Impact: Decodable {
        let component_id: String
        let status: String
        let current_status: String?
    }
    private struct Incident: Decodable {
        let id: String
        let name: String
        let status: String
        let affected_components: [Impact]
        let component_impacts: [Period]
    }
    private struct Period: Decodable {
        let component_id: String
        let status: String
        let end_at: String?
    }
    private struct Structure: Decodable { let items: [Item] }
    private struct Item: Decodable { let group: Group? }
    private struct Group: Decodable {
        let id: String
        let name: String
        let components: [Member]
    }
    private struct Member: Decodable { let component_id: String }

    static func decode(_ data: Data) throws -> ServiceHealthSnapshot {
        let summary = try JSONDecoder().decode(Document.self, from: data).summary
        guard summary.id == "01JMDK9XYNY6RXSED6SDWW50WY",
              !summary.components.isEmpty, summary.components.count <= 200,
              summary.affected_components.count <= 200, summary.ongoing_incidents.count <= 100,
              summary.structure.items.count <= 100,
              Set(summary.components.map(\.id)).count == summary.components.count,
              Set(summary.affected_components.map(\.component_id)).count == summary.affected_components.count,
              Set(summary.ongoing_incidents.map(\.id)).count == summary.ongoing_incidents.count
        else { throw ServiceHealthError.malformed }
        let ids = Set(summary.components.map(\.id))
        guard Set(summary.affected_components.map(\.component_id)).isSubset(of: ids)
        else { throw ServiceHealthError.malformed }
        let impacts = Dictionary(uniqueKeysWithValues: summary.affected_components.map { ($0.component_id, $0.current_status ?? $0.status) })
        let components = summary.components.map {
            ServiceComponent(id: $0.id, name: $0.name, status: impacts[$0.id] ?? "operational")
        }
        let groups = try summary.structure.items.compactMap { item -> WatchedService? in
            guard let group = item.group else { return nil }
            guard group.components.count <= 200 else { throw ServiceHealthError.malformed }
            let members = Set(group.components.map(\.component_id))
            guard members.isSubset(of: ids) else { throw ServiceHealthError.malformed }
            guard let key = WatchedService.openAIGroupIDs[group.id] else { return nil }
            return .init(id: key, name: group.name, componentIDs: members)
        }
        guard Set(groups.map(\.id)).count == groups.count else { throw ServiceHealthError.malformed }
        let incidents = try summary.ongoing_incidents.map { item -> ServiceIncident in
            guard item.affected_components.count <= 200, item.component_impacts.count <= 2000
            else { throw ServiceHealthError.malformed }
            let ongoing = item.component_impacts.filter { $0.end_at == nil }
            let members = Set(ongoing.map(\.component_id)).union(item.affected_components.map(\.component_id))
            let levels = ongoing.map { ServiceHealthLevel(componentStatus: $0.status) }
                + item.affected_components.map { ServiceHealthLevel(componentStatus: $0.current_status ?? $0.status) }
            let impact = levels.contains(.outage) ? "major" : levels.contains(.unknown) ? "unknown" : "minor"
            return .init(id: item.id, name: item.name, status: item.status, impact: impact, componentIDs: members)
        }
        return .init(components: components, incidents: incidents, groups: groups)
    }
}
