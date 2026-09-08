import Foundation
import UsageCore

private final class StatusRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard request.url?.scheme == "https", request.url?.host == task.originalRequest?.url?.host else { return nil }
        return request
    }
}

// Public status requests are independent of CLI authentication and usage transport.
public actor ServiceHealthClient {
    public static let maximumBytes = 262_144
    private let session: URLSession
    private var cached: [Provider: (snapshot: ServiceHealthSnapshot, etag: String?)] = [:]

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration, delegate: StatusRedirectPolicy(), delegateQueue: nil)
    }

    public func read(_ provider: Provider) async throws -> ServiceHealthSnapshot {
        var request = URLRequest(url: provider.statusFeedURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Sparebar service-status", forHTTPHeaderField: "User-Agent")
        if let etag = cached[provider]?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw ServiceHealthError.unavailable }
        if response.statusCode == 304 {
            guard let snapshot = cached[provider]?.snapshot else { throw ServiceHealthError.malformed }
            return snapshot
        }
        guard response.statusCode == 200 else {
            throw ServiceHealthError.http(
                response.statusCode, retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        }
        guard response.expectedContentLength <= Self.maximumBytes else { throw ServiceHealthError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumBytes else { throw ServiceHealthError.responseTooLarge }
            data.append(byte)
        }
        let snapshot = try ServiceHealthSnapshot(data: data)
        cached[provider] = (snapshot, response.value(forHTTPHeaderField: "ETag"))
        return snapshot
    }

    public static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite { return min(31_536_000, max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { min(31_536_000, max(0, $0.timeIntervalSince(now))) }
    }
}
