import Darwin
import Foundation
import UsageCore

struct ResetRecord: Codable {
    var receipts: [String: Date] = [:]
    var pending: ResetAttempt?
}

// Only account fingerprints, request IDs and dates; never credentials.
// The lock serializes read/modify/write across local app instances.
struct ResetLedger {
    let directory: URL
    static var standard: Self {
        Self(
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Sparebar/Resets"))
    }
    private struct Document: Codable {
        var version = 1
        var accounts: [String: ResetRecord] = [:]
    }
    enum Failure: Error { case storage, pendingRequest, changedRequest }
    func record(for account: String) throws -> ResetRecord {
        try transaction(write: false) { $0.accounts[account] ?? ResetRecord() }
    }
    func begin(_ attempt: ResetAttempt) throws {
        try transaction { document in
            var record = document.accounts[attempt.accountKey] ?? ResetRecord()
            guard record.pending == nil else { throw Failure.pendingRequest }
            record.pending = attempt
            document.accounts[attempt.accountKey] = record
        }
    }
    func finish(_ attempt: ResetAttempt, redeemed: Bool) throws {
        try transaction { document in
            var record = document.accounts[attempt.accountKey] ?? ResetRecord()
            guard record.pending == attempt else { throw Failure.changedRequest }
            if redeemed { record.receipts[attempt.id] = record.receipts[attempt.id] ?? Date() }
            record.pending = nil
            document.accounts[attempt.accountKey] = record
        }
    }
    private func transaction<T>(write: Bool = true, _ operation: (inout Document) throws -> T) throws -> T {
        let fm = FileManager.default
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(
            directory.appendingPathComponent("ledger.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw Failure.storage }
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.storage }
        let file = directory.appendingPathComponent("ledger.json")
        var document = Document()
        if fm.fileExists(atPath: file.path) {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == 1 else { throw Failure.storage }
        }
        let result = try operation(&document)
        if write {
            try JSONEncoder().encode(document).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw Failure.storage }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw Failure.storage }
            let parent = open(directory.path, O_RDONLY)
            guard parent >= 0 else { throw Failure.storage }
            defer { close(parent) }
            guard fsync(parent) == 0 else { throw Failure.storage }
        }
        return result
    }
}
