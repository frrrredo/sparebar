import Foundation

/// Provider-owned status categories. Component membership verified on the official pages.
/// OpenAI: https://status.openai.com/; Claude: https://status.claude.com/ (2026-09-09).
public struct WatchedService: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let componentIDs: Set<String>
    public init(id: String, name: String, componentIDs: Set<String>) {
        self.id = id
        self.name = name
        self.componentIDs = componentIDs
    }

    public static let openAIGroupIDs: [String: String] = [
        "01K5H8S53SY1KMS4GQMNMQM1K5": "api",
        "01K5H8S53SY1KMS4GQMNMZXTR1": "chatgpt",
        "01KMKF9EBTCD8BN9PG8DJZXRSQ": "codex",
        "01KKACDSZF5G5JTBJY83GF176Z": "fedramp",
        "01KTQBYDGR2AKA7D6HW6RVAGZC": "ads",
    ]

    public static func defaults(for provider: Provider) -> Set<String> {
        provider == .codex ? ["chatgpt", "codex"] : ["chat", "code"]
    }

    public static func catalog(for provider: Provider) -> [WatchedService] {
        provider == .codex ? openAI : claude
    }

    private static let openAI: [WatchedService] = [
        .init(id: "api", name: "APIs", componentIDs: [
            "01JMXBRMFE6N2NNT7DG6XZQ6PW",
            "01JP8CD9JR3HR6Y7G4Q75N4DVW",
            "01JMXBRMFEMZK0HPK19RYET250",
            "01JMXBRMFEV0AJ0VVS68N9CD6R",
            "01JMXBRMFE4MAP2BHSJNZ787WX",
            "01JMXBRMFE5ESNNV8JDHVCGSRD",
            "01JMXBRMFEKVBWKK82B44QFMCE",
            "01JMXBRMFEVZ7E0X9GD9FWR9WX",
            "01JMXBRMFEQW613TFE89F45035",
            "01JMXBRMFESJCBGJR10PDD3WCQ",
            "01JSM5RTJWHRWDTS6Q604VEW3B",
            "01K9G527YRPY1EFRMHTKB5BKT5",
        ]),
        .init(id: "chatgpt", name: "ChatGPT", componentIDs: [
            "01JMXBNJXGV1T5GT2M9XA83XNG",
            "01JMXBNJXG1S2D9V65P1ZZTD94",
            "01KX45G1SH21AX5DT93D4HMF0P",
            "01KMKFAMWKQ81YWSE1Z18R6VHR",
            "01JNKS9D9S72PMP1938PVFFQN4",
            "01JMXBNJXGKKP51D4DEJ2HZJ8Q",
            "01JMXBNJXG1YMQPPCPCQX3MPA2",
            "01JMXBNJXGGT5SR5DB9J7GYY48",
            "01JSFK5QX36ZRW0TW0ZV0ZYFXQ",
            "01JQ7EKW990MSPSWVXC7VPV2ZJ",
            "01JSYVYQSWMJ9QG35XHP08BHA7",
            "01JSG1XMJ9RVJJQ0E85NVSJ2AZ",
            "01K8C008QVXHA6JX98PAS42VPD",
            "01KX45G1SHQQ9DTAX9S4W7FV8G",
            "01K6TVGGGDCP0PPGCHXAG3AQX8",
        ]),
        .init(id: "codex", name: "Codex", componentIDs: [
            "01JVCV8YSWZFRSM1G5CVP253SK",
            "01KMP3KP5MGE23B80K1EK4S8PV",
            "01KMKFAMWKNQ84Z1766MV08ZDE",
            "01KMP3KP5M8X0EBTVW6KN327EE",
        ]),
        .init(id: "fedramp", name: "FedRAMP", componentIDs: [
            "01KKAD7C71MCCH3FTREMJH4AAS",
        ]),
        .init(id: "ads", name: "Ads Platform", componentIDs: [
            "01KTQBYVARFJ5KMCSECM06VKCF",
            "01KVR95C58GGWHV7RYBT32NP11",
        ]),
    ]

    private static let claude: [WatchedService] = [
        .init(id: "chat", name: "claude.ai", componentIDs: ["rwppv331jlwc"]),
        .init(id: "console", name: "Claude Console", componentIDs: ["0qbwn08sd68x"]),
        .init(id: "api", name: "Claude API", componentIDs: ["k8w3r06qmzrp"]),
        .init(id: "code", name: "Claude Code", componentIDs: ["yyzkbfz2thpt"]),
        .init(id: "cowork", name: "Claude Cowork", componentIDs: ["bpp5gb3hpjcl"]),
        .init(id: "government", name: "Claude for Government", componentIDs: ["0scnb50nvy53"]),
    ]
}

extension ServiceHealthSnapshot {
    public func filtered(for provider: Provider, services: Set<String>) -> ServiceHealthSnapshot {
        let options = WatchedService.catalog(for: provider).filter { services.contains($0.id) }
        // OpenAI publishes current membership in every report. If a group moves
        // or disappears, do not silently fall back to an older component list.
        let catalog = options.compactMap { option in
            provider == .codex ? groups.first(where: { $0.id == option.id }) : option
        }
        let missingGroup = catalog.count != options.count || catalog.contains { $0.componentIDs.isEmpty }
        let watched = Set(catalog.flatMap(\.componentIDs))
        let included = components.filter { watched.contains($0.id) }
        let known = Set(components.map(\.id))
        let scoped = incidents.filter { !$0.componentIDs.isDisjoint(with: watched) }.map { incident in
            let levels = included.filter { incident.componentIDs.contains($0.id) }.map(\.level)
            // A severe excluded component must not escalate a mild selected one.
            let impact = incident.componentIDs.isSubset(of: watched) ? incident.impact :
                levels.contains(.outage) ? "major" : levels.contains(.unknown) ? "unknown" : "minor"
            return ServiceIncident(id: incident.id, name: incident.name, status: incident.status,
                                   impact: impact, componentIDs: incident.componentIDs.intersection(watched))
        }
        let unscoped = incidents.filter { $0.componentIDs.isEmpty || !$0.componentIDs.isSubset(of: known) }
        let unexplainedRollup = indicator.map { $0 != "none" } == true
            && affected.isEmpty && incidents.isEmpty
        return .init(components: included, incidents: scoped, groups: groups,
                     unscopedIncidents: unscoped,
                     scopeIncomplete: missingGroup || !watched.isSubset(of: known) || unexplainedRollup)
    }
}
