import Foundation
import Testing

@testable import UsageCore
@testable import UsageProviders

struct CodexResetTransportTests {
    func fixture(mode: String) throws -> (URL, ConnectionOptions, ResetAttempt) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reset transport \(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("codex")
        try Self.server.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try mode.write(to: dir.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let identity = try Normalize.codexIdentity([
            "account": ["type": "chatgpt", "email": "example@example.invalid"]
        ])
        let key = Normalize.fingerprint([identity, ""])
        return (
            dir, ConnectionOptions(executable: script.path),
            ResetAttempt(accountKey: key, meterID: "codex:10080")
        )
    }
    @Test func droppedResponseReplaysSameRequestAndNeverConsumesTwice() async throws {
        let (dir, options, attempt) = try fixture(mode: "drop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = await CodexReset.consume(attempt, options: options, retry: false)
        guard case .uncertain = first else {
            Issue.record("Expected uncertain response")
            return
        }
        let second = await CodexReset.consume(attempt, options: options, retry: true)
        guard case .completed(.alreadyRedeemed) = second else {
            Issue.record("Expected idempotent receipt")
            return
        }
        let used = try String(contentsOf: dir.appendingPathComponent("used"), encoding: .utf8)
        #expect(used.split(separator: "\n").count == 1)
        #expect(used.trimmingCharacters(in: .whitespacesAndNewlines) == attempt.id)
        // The standard provider read path never issues a consume request.
        guard case .success(let snapshot, _, _) = await ProviderReader.read(.codex, options: options) else {
            Issue.record("Expected authoritative post-reset usage")
            return
        }
        #expect(snapshot.resetCredits == 2)
        #expect(snapshot.preferred?.remaining == 83)
    }
    @Test(arguments: [
        "healthy", "empty", "unsupported", "account-change", "malformed", "noCredit", "nothingToReset",
    ])
    func nonSuccessAndPreflightPaths(mode: String) async throws {
        let (dir, options, attempt) = try fixture(mode: mode)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await CodexReset.consume(attempt, options: options, retry: false)
        switch (mode, result) {
        case ("healthy", .completed(.nothingToReset)), ("empty", .completed(.noCredit)),
            ("unsupported", .notSent(.unsupported)), ("account-change", .notSent(.accountChanged)),
            ("malformed", .uncertain(.malformed)), ("noCredit", .completed(.noCredit)),
            ("nothingToReset", .completed(.nothingToReset)):
            break
        default: Issue.record("Unexpected result for \(mode)")
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("used").path))
        if ["healthy", "empty", "account-change"].contains(mode) {
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("requests").path))
        }
    }
    @Test func usageReadAllowlistStillRefusesResetMutation() throws {
        let process = try LineProcess(
            executable: "/bin/cat", arguments: [], environment: [:], directory: "/tmp")
        defer { process.stop() }
        #expect(throws: UsageIssue.unexpectedMessage) {
            try ProviderReader.codexRequest(
                process, id: 1, method: "account/rateLimitResetCredit/consume", params: [:])
        }
    }
    static let server = #"""
        #!/usr/bin/python3
        import json, pathlib, sys
        root = pathlib.Path(__file__).parent
        mode = (root / 'mode').read_text()
        if '--version' in sys.argv:
            print('codex 0.0.0'); sys.exit(0)
        for line in sys.stdin:
            request = json.loads(line)
            method = request['method']
            if 'id' not in request: continue
            result = {}
            error = None
            used = (root / 'used').read_text().splitlines() if (root / 'used').exists() else []
            if method == 'account/read':
                email = 'other@example.invalid' if mode == 'account-change' and request['id'] == 4 else 'example@example.invalid'
                result = {'account': {'type': 'chatgpt', 'email': email}}
            elif method == 'account/rateLimits/read':
                result = {'rateLimits': {'primary': {'usedPercent': 17 if used or mode == 'healthy' else 94,
                           'windowDurationMins': 10080, 'resetsAt': 1900000000}},
                          'rateLimitResetCredits': {'availableCount': 0 if mode == 'empty' else 3-len(used)}}
            elif method == 'account/rateLimitResetCredit/consume':
                key = request['params']['idempotencyKey']
                with (root / 'requests').open('a') as out: out.write(key + '\n')
                if mode == 'unsupported': error = {'code': -32601}
                elif mode == 'malformed': result = {'unexpected': True}
                elif mode in ['noCredit', 'nothingToReset']: result = {'outcome': mode}
                elif key in used: result = {'outcome': 'alreadyRedeemed'}
                else:
                    with (root / 'used').open('a') as out: out.write(key + '\n')
                    if mode == 'drop': sys.exit(0)
                    result = {'outcome': 'reset'}
            elif method != 'initialize': raise RuntimeError('Unexpected method')
            print(json.dumps({'id': request['id'], **({'error': error} if error else {'result': result})}), flush=True)
        """#
}
