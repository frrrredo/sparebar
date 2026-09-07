import Foundation
import UsageCore
import UsageProviders

@main struct UsageCheck {
    static func main() async {
        var failures = 0
        for provider in Provider.allCases {
            let start = Date()
            let result = await ProviderReader.read(provider)
            switch result {
            case .success(let snapshot, _, let version):
                let meters: [[String: Any]] = snapshot.allowances.map { meter in
                    [
                        "label": meter.label, "used": meter.used, "remaining": meter.remaining,
                        "reset": meter.resetsAt.map { ISO8601DateFormatter().string(from: $0) }
                            ?? "not provided",
                    ]
                }
                printJSON([
                    "provider": provider.rawValue, "status": "connected", "version": version,
                    "seconds": Date().timeIntervalSince(start), "meters": meters,
                ])
            case .failure(let issue, _, _):
                failures += 1
                printJSON([
                    "provider": provider.rawValue, "status": issue.rawValue,
                    "seconds": Date().timeIntervalSince(start),
                ])
            }
        }
        if failures == Provider.allCases.count { exit(1) }
    }
    static func printJSON(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            print(text)
        }
    }
}
