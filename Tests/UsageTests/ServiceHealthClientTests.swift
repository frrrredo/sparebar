import Foundation
import Testing
import UsageCore
@testable import UsageProviders

private final class StatusResponses: @unchecked Sendable {
    struct Reply {
        var code = 200
        var headers: [String: String] = [:]
        var data = Data()
    }
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var requests: [URLRequest] = []
    func reset(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        self.replies = replies
        requests = []
    }
    func next(_ request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return replies.isEmpty ? .init(code: 500) : replies.removeFirst()
    }
    var captured: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

private final class StatusProtocol: URLProtocol, @unchecked Sendable {
    static let responses = StatusResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.responses.next(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.code, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct ServiceHealthClientTests {
    private let healthy = Data(#"{"components":[{"id":"service","name":"Claude Code","status":"operational"}],"incidents":[],"status":{"indicator":"none"}}"#.utf8)
    private func client() -> ServiceHealthClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusProtocol.self]
        return ServiceHealthClient(configuration: configuration)
    }

    @Test func everyCheckRevalidatesAndNotModifiedReusesOnlyTheMatchingProvider() async throws {
        StatusProtocol.responses.reset([
            .init(headers: ["ETag": "sample-tag", "Set-Cookie": "sample=ignored"], data: healthy),
            .init(code: 304),
            .init(code: 304),
        ])
        let client = client()
        let first = try await client.read(.claude)
        let second = try await client.read(.claude)
        #expect(first == second)
        do { _ = try await client.read(.codex); Issue.record("A 304 without a provider cache was accepted") }
        catch ServiceHealthError.malformed {} catch { Issue.record("Unexpected failure: \(error)") }
        let requests = StatusProtocol.responses.captured
        #expect(requests.count == 3)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "sample-tag")
        #expect(requests[2].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(requests.map(\.url) == [Provider.claude.statusFeedURL, Provider.claude.statusFeedURL, Provider.codex.statusFeedURL])
    }

    @Test func responsesWithoutValidatorsAreFetchedAgainAndHttpErrorsRemainErrors() async throws {
        StatusProtocol.responses.reset([
            .init(data: healthy), .init(data: healthy),
            .init(code: 429, headers: ["Retry-After": "1800"]),
        ])
        let client = client()
        _ = try await client.read(.claude)
        _ = try await client.read(.claude)
        #expect(StatusProtocol.responses.captured.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
        do { _ = try await client.read(.claude); Issue.record("Rate limit was accepted as service status") }
        catch ServiceHealthError.http(let code, let retry) { #expect(code == 429); #expect(retry == 1800) }
        catch { Issue.record("Unexpected failure: \(error)") }
    }

    @Test func oversizedAndMalformedBodiesAreRejected() async {
        StatusProtocol.responses.reset([
            .init(headers: ["Content-Length": String(ServiceHealthClient.maximumBytes + 1)]),
            .init(data: Data(repeating: 65, count: ServiceHealthClient.maximumBytes + 1)),
            .init(data: Data("not a status response".utf8)),
        ])
        let client = client()
        for _ in 0..<2 {
            do { _ = try await client.read(.claude); Issue.record("Oversized response was accepted") }
            catch ServiceHealthError.responseTooLarge {} catch { Issue.record("Unexpected failure: \(error)") }
        }
        await #expect(throws: (any Error).self) { try await client.read(.claude) }
    }

    @Test func openAINativeReportUsesOneRequestAndRetainsProductGroups() async throws {
        let data = Data(#"{"summary":{"id":"01JMDK9XYNY6RXSED6SDWW50WY","components":[{"id":"sample","name":"Sample chat"}],"affected_components":[],"ongoing_incidents":[],"structure":{"items":[{"group":{"id":"01K5H8S53SY1KMS4GQMNMZXTR1","name":"ChatGPT","components":[{"component_id":"sample"}]}}]}}}"#.utf8)
        StatusProtocol.responses.reset([.init(data: data)])
        let snapshot = try await client().read(.codex)
        #expect(snapshot.filtered(for: .codex, services: ["chatgpt"]).level == .operational)
        #expect(StatusProtocol.responses.captured.count == 1)
        #expect(StatusProtocol.responses.captured.first?.url?.path == "/proxy/status.openai.com")
    }
}
