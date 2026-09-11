import Foundation
import UsageCore

public struct ConnectionOptions: Sendable {
    public var executable: String?
    public var configDirectory: String?
    public init(executable: String? = nil, configDirectory: String? = nil) {
        self.executable = executable
        self.configDirectory = configDirectory
    }
}

public enum CLIDiscovery {
    public static func resolve(
        _ provider: Provider, custom: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fm = FileManager.default
        if let custom, !custom.isEmpty {
            let path = NSString(string: custom).expandingTildeInPath
            return path.hasPrefix("/") && fm.isExecutableFile(atPath: path) ? path : nil
        }
        let home = fm.homeDirectoryForCurrentUser.path
        var folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "/usr/bin",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        let versions = (try? fm.contentsOfDirectory(atPath: nvm)) ?? []
        folders += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map {
            "\(nvm)/\($0)/bin"
        }
        return folders.filter { $0.hasPrefix("/") }.map { "\($0)/\(provider.rawValue)" }.first {
            fm.isExecutableFile(atPath: $0)
        }
    }
    static func environment(executable: String, provider: Provider, options: ConnectionOptions) -> [String:
        String]
    {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let binary = URL(fileURLWithPath: executable)
        let paths = [
            binary.deletingLastPathComponent().path,
            binary.resolvingSymlinksInPath().deletingLastPathComponent().path,
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]
        env["PATH"] = (paths + (env["PATH"] ?? "").split(separator: ":").map(String.init)).joined(
            separator: ":")
        if let folder = options.configDirectory, !folder.isEmpty {
            env[provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] =
                NSString(string: folder).expandingTildeInPath
        }
        if provider == .claude {
            env["DISABLE_TELEMETRY"] = "1"
            env["DISABLE_ERROR_REPORTING"] = "1"
            env["DISABLE_AUTOUPDATER"] = "1"
        }
        // Preserve existing traffic restrictions, provider roots, and managed policy.
        return env
    }
}

public enum ProviderReader {
    public static func read(_ provider: Provider, options: ConnectionOptions = .init()) async -> ReadOutcome {
        let group = ProcessGroup()
        let worker = Task.detached(priority: .utility) { readSync(provider, options: options, group: group) }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            group.cancel()
            worker.cancel()
        }
    }
    static func readSync(_ provider: Provider, options: ConnectionOptions, group: ProcessGroup) -> ReadOutcome
    {
        defer { group.finish() }
        guard let executable = CLIDiscovery.resolve(provider, custom: options.executable) else {
            return .failure(.missingCLI, accountKey: nil, executable: nil)
        }
        var identity: String?
        do {
            let directory = try workingDirectory()
            let env = CLIDiscovery.environment(executable: executable, provider: provider, options: options)
            func process(_ arguments: [String], timeout: TimeInterval = 25) throws -> LineProcess {
                let session = try LineProcess(
                    executable: executable, arguments: arguments, environment: env, directory: directory,
                    timeout: timeout)
                try group.add(session)
                return session
            }
            let versionProcess = try process(["--version"], timeout: 8)
            let rawVersion = String(data: try versionProcess.capture(), encoding: .utf8) ?? ""
            versionProcess.stop()
            let version =
                rawVersion.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map {
                    String(rawVersion[$0])
                } ?? "Unknown"
            if provider == .codex {
                let session = try process([
                    "-c", "features.apps=false", "-c", "features.plugins=false", "app-server", "--stdio",
                ])
                _ = try codexRequest(
                    session, id: 1, method: "initialize",
                    params: [
                        "clientInfo": [
                            "name": "sparebar",
                            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                                ?? "dev",
                        ]
                    ])
                try session.send(["method": "initialized", "params": [:]])
                let account = try codexRequest(
                    session, id: 2, method: "account/read", params: ["refreshToken": false])
                let before = try Normalize.codexIdentity(account)
                let usage = try codexRequest(session, id: 3, method: "account/rateLimits/read", params: [:])
                let after = try Normalize.codexIdentity(
                    codexRequest(session, id: 4, method: "account/read", params: ["refreshToken": false]))
                guard before == after else { throw UsageIssue.accountChanged }
                let snapshot = try Normalize.codex(
                    usage, identity: before,
                    accountLabel: Normalize.label(
                        (account["account"] as? [String: Any])?["email"], fallback: "Signed-in Codex account")
                )
                identity = snapshot.accountKey
                return .success(snapshot, executable: executable, version: version)
            } else {
                func auth() throws -> String {
                    let session = try process(["auth", "status", "--json"], timeout: 12)
                    defer { session.stop() }
                    let data = try session.capture()
                    guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { throw UsageIssue.malformed }
                    return try Normalize.claudeIdentity(document)
                }
                let before = try auth()
                identity = before
                let session = try process([
                    "--safe-mode", "--no-chrome", "--tools", "", "--no-session-persistence", "--print",
                    "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                ])
                _ = try claudeRequest(session, id: "sparebar-init", request: ["subtype": "initialize"])
                let usage = try claudeRequest(
                    session, id: "sparebar-usage", request: ["subtype": "get_usage", "skip_behaviors": true])
                session.stop()
                let after = try auth()
                guard before == after else { throw UsageIssue.accountChanged }
                return .success(
                    try Normalize.claude(usage, identity: before), executable: executable, version: version)
            }
        } catch let issue as UsageIssue {
            return .failure(issue, accountKey: identity, executable: executable)
        } catch {
            return .failure(.malformed, accountKey: identity, executable: executable)
        }
    }
    static func workingDirectory() throws -> String {
        let fm = FileManager.default
        let directory = fm.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Sparebar/Probe", isDirectory: true)
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory.path
    }
    public static func codexRequest(_ process: LineProcess, id: Int, method: String, params: [String: Any])
        throws -> [String: Any]
    {
        guard ["initialize", "account/read", "account/rateLimits/read"].contains(method) else {
            throw UsageIssue.unexpectedMessage
        }
        try process.send(["id": id, "method": method, "params": params])
        return try codexResponse(process, id: id)
    }
    static func codexResponse(_ process: LineProcess, id: Int) throws -> [String: Any] {
        while true {
            let message = try process.json()
            if message["method"] != nil && message["id"] != nil { throw UsageIssue.unexpectedMessage }
            guard message["id"] as? Int == id else { continue }
            if let error = message["error"] as? [String: Any] {
                if error["code"] as? Int == -32601 { throw UsageIssue.unsupported }
                throw UsageIssue.unavailable
            }
            guard let result = message["result"] as? [String: Any] else { throw UsageIssue.malformed }
            return result
        }
    }
    public static func claudeRequest(_ process: LineProcess, id: String, request: [String: Any]) throws
        -> [String: Any]
    {
        guard let subtype = request["subtype"] as? String, ["initialize", "get_usage"].contains(subtype),
            subtype != "get_usage" || request["skip_behaviors"] as? Bool == true
        else { throw UsageIssue.unexpectedMessage }
        try process.send(["type": "control_request", "request_id": id, "request": request])
        while true {
            let message = try process.json()
            if ["control_request", "assistant", "user", "result"].contains(message["type"] as? String ?? "") {
                throw UsageIssue.unexpectedMessage
            }
            guard message["type"] as? String == "control_response",
                let response = message["response"] as? [String: Any], response["request_id"] as? String == id
            else { continue }
            guard response["subtype"] as? String == "success" else { throw UsageIssue.unsupported }
            guard let data = response["response"] as? [String: Any] else { throw UsageIssue.malformed }
            return data
        }
    }
}
