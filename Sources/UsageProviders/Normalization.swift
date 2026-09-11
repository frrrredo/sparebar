import CoreFoundation
import CryptoKit
import Foundation
import UsageCore

public enum Normalize {
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite
        else { return nil }
        return n.doubleValue
    }
    static func percent(_ value: Any?) -> Double? {
        guard let n = number(value), (0...100).contains(n) else { return nil }
        return n
    }
    static func label(_ value: Any?, fallback: String) -> String {
        guard let text = value as? String, !text.isEmpty else { return fallback }
        return String(
            text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80).map(
                Character.init))
    }
    public static func fingerprint(_ components: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func codexIdentity(_ response: [String: Any]) throws -> String {
        guard let account = response["account"] as? [String: Any] else { throw UsageIssue.signIn }
        guard account["type"] as? String == "chatgpt" else { throw UsageIssue.subscriptionRequired }
        guard let email = account["email"] as? String, !email.isEmpty else { throw UsageIssue.unavailable }
        return fingerprint(["codex", email])
    }
    public static func claudeIdentity(_ auth: [String: Any]) throws -> String {
        guard auth["loggedIn"] as? Bool == true else { throw UsageIssue.signIn }
        guard auth["authMethod"] as? String == "claude.ai", auth["apiProvider"] as? String == "firstParty"
        else { throw UsageIssue.subscriptionRequired }
        guard let email = auth["email"] as? String, !email.isEmpty else { throw UsageIssue.unavailable }
        return fingerprint([
            "claude", email, auth["orgId"] as? String ?? "", auth["subscriptionType"] as? String ?? "",
        ])
    }
    public static func codex(
        _ document: [String: Any], identity: String, now: Date = Date(), accountLabel: String? = nil
    ) throws
        -> UsageSnapshot
    {
        var buckets = document["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        if buckets.isEmpty, let single = document["rateLimits"] as? [String: Any] {
            buckets[single["limitId"] as? String ?? "codex"] = single
        }
        var meters: [Allowance] = []
        for (key, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            for position in ["primary", "secondary"] {
                guard let window = bucket[position] as? [String: Any],
                    let used = percent(window["usedPercent"]),
                    let minutes = number(window["windowDurationMins"]), (1...5_256_000).contains(minutes),
                    minutes.rounded() == minutes
                else { continue }
                let weekly = minutes == 10_080
                let period = weekly ? "Weekly" : minutes == 300 ? "5-hour" : "\(Int(minutes)) min"
                let main = key == "codex"
                let title = main ? period : "\(label(bucket["limitName"], fallback: key)) / \(period)"
                let reset = number(window["resetsAt"]).flatMap {
                    (1...32_503_680_000).contains($0) ? Date(timeIntervalSince1970: $0) : nil
                }
                meters.append(
                    Allowance(
                        id: "\(key):\(Int(minutes))", label: title, used: used, resetsAt: reset,
                        weekly: weekly, isMain: main))
            }
        }
        guard !meters.isEmpty else { throw UsageIssue.unavailable }
        let credits = (document["rateLimitResetCredits"] as? [String: Any]).flatMap {
            number($0["availableCount"])
        }.flatMap { $0 >= 0 && $0 < 100_000 && $0.rounded() == $0 ? Int($0) : nil }
        var creditIDs = Set<String>()
        let details =
            ((document["rateLimitResetCredits"] as? [String: Any])?["credits"] as? [[String: Any]] ?? [])
            .compactMap { row -> ResetCredit? in
                guard let id = row["id"] as? String, !id.isEmpty, id.count <= 512,
                    row["status"] as? String == "available", row["resetType"] as? String == "codexRateLimits",
                    creditIDs.insert(id).inserted
                else { return nil }
                let expiry = number(row["expiresAt"]).flatMap {
                    (1...32_503_680_000).contains($0) ? Date(timeIntervalSince1970: $0) : nil
                }
                return ResetCredit(
                    id: id, title: label(row["title"], fallback: "Codex usage reset"),
                    description: (row["description"] as? String).map { label($0, fallback: "") },
                    expiresAt: expiry)
            }
        // The usage response provides account/workspace association beyond account/read.
        let accountKey = fingerprint([identity, document["accountId"] as? String ?? ""])
        return UsageSnapshot(
            provider: .codex, accountKey: accountKey, allowances: unique(meters), checkedAt: now,
            resetCredits: credits, resetDetails: details, accountLabel: accountLabel)
    }
    public static func claude(_ document: [String: Any], identity: String, now: Date = Date()) throws
        -> UsageSnapshot
    {
        guard let limits = document["rate_limits"] as? [String: Any] else { throw UsageIssue.unavailable }
        var meters: [Allowance] = []
        for (key, title, weekly) in [("seven_day", "Weekly", true), ("five_hour", "5-hour", false)] {
            if let window = limits[key] as? [String: Any], let used = percent(window["utilization"]) {
                meters.append(
                    Allowance(
                        id: key, label: title, used: used, resetsAt: iso(window["resets_at"]), weekly: weekly,
                        isMain: true))
            }
        }
        for row in limits["limits"] as? [[String: Any]] ?? [] {
            guard let kind = row["kind"] as? String, let used = percent(row["percent"]) else { continue }
            let reset = iso(row["resets_at"])
            if kind == "weekly_scoped", let scope = row["scope"] as? [String: Any],
                let model = scope["model"] as? [String: Any],
                let name = model["display_name"] as? String, !name.isEmpty
            {
                let id = model["id"] as? String ?? name
                meters.append(
                    Allowance(
                        id: "model:\(id):weekly", label: "\(label(name, fallback: "Model")) / Weekly",
                        used: used, resetsAt: reset, weekly: true, isMain: false))
            } else if kind == "weekly_all" || kind == "session" {
                let weekly = kind == "weekly_all"
                meters.append(
                    Allowance(
                        id: weekly ? "seven_day" : "five_hour", label: weekly ? "Weekly" : "5-hour",
                        used: used, resetsAt: reset, weekly: weekly, isMain: true))
            }
        }
        guard !meters.isEmpty else { throw UsageIssue.unavailable }
        return UsageSnapshot(
            provider: .claude, accountKey: identity, allowances: unique(meters), checkedAt: now)
    }
    static func unique(_ meters: [Allowance]) -> [Allowance] {
        var ids = Set<String>()
        return meters.filter { ids.insert($0.id).inserted }
    }
    static func iso(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
