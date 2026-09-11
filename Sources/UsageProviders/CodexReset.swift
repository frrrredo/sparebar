import Foundation
import UsageCore

// Deliberately separate from the read-only request allowlist. Only an explicit,
// durably recorded user action reaches this operation.
public enum CodexReset {
    public static func consume(_ attempt: ResetAttempt, options: ConnectionOptions, retry: Bool) async
        -> ResetOutcome
    {
        let group = ProcessGroup()
        let worker = Task.detached(priority: .userInitiated) {
            run(attempt, options: options, retry: retry, group: group)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            group.cancel()
            worker.cancel()
        }
    }

    static func run(_ attempt: ResetAttempt, options: ConnectionOptions, retry: Bool, group: ProcessGroup)
        -> ResetOutcome
    {
        defer { group.finish() }
        var sent = false
        do {
            guard let executable = CLIDiscovery.resolve(.codex, custom: options.executable) else {
                throw UsageIssue.missingCLI
            }
            let session = try LineProcess(
                executable: executable,
                arguments: [
                    "-c", "features.apps=false", "-c", "features.plugins=false", "app-server", "--stdio",
                ],
                environment: CLIDiscovery.environment(
                    executable: executable, provider: .codex, options: options),
                directory: ProviderReader.workingDirectory(), timeout: 35)
            try group.add(session)
            _ = try ProviderReader.codexRequest(
                session, id: 1, method: "initialize",
                params: ["clientInfo": ["name": "sparebar", "version": "1"]])
            try session.send(["method": "initialized", "params": [:]])
            let identity = try Normalize.codexIdentity(
                ProviderReader.codexRequest(
                    session, id: 2,
                    method: "account/read", params: ["refreshToken": false]))
            let snapshot = try Normalize.codex(
                ProviderReader.codexRequest(
                    session, id: 3,
                    method: "account/rateLimits/read", params: [:]), identity: identity)
            guard snapshot.accountKey == attempt.accountKey else { throw UsageIssue.accountChanged }
            if !retry {
                guard snapshot.resetCredits.map({ $0 > 0 }) == true else { return .completed(.noCredit) }
                guard let meter = snapshot.allowances.first(where: { $0.id == attempt.meterID }),
                    !meter.expired(at: Date()), meter.remaining <= 10
                else { return .completed(.nothingToReset) }
            }
            let after = try Normalize.codexIdentity(
                ProviderReader.codexRequest(
                    session, id: 4,
                    method: "account/read", params: ["refreshToken": false]))
            guard after == identity else { throw UsageIssue.accountChanged }
            // Mark uncertain before writing: even a partial write must keep the same key.
            sent = true
            try session.send([
                "id": 5, "method": "account/rateLimitResetCredit/consume",
                "params": ["idempotencyKey": attempt.id],
            ])
            let response = try ProviderReader.codexResponse(session, id: 5)
            guard let raw = response["outcome"] as? String, let result = ResetDisposition(rawValue: raw)
            else {
                throw UsageIssue.malformed
            }
            return .completed(result)
        } catch let issue as UsageIssue {
            if issue == .unsupported { return .notSent(issue) }
            return sent ? .uncertain(issue) : .notSent(issue)
        } catch {
            return sent ? .uncertain(.unavailable) : .notSent(.unavailable)
        }
    }
}
