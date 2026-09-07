import Darwin
import Foundation
import UsageCore

// Every helper has its own process group. Cancellation stops only that group,
// including descendants, even if a CLI launcher forks a runtime process.
public final class ProcessGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var sessions: [LineProcess] = []
    public init() {}
    func add(_ session: LineProcess) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            session.stop()
            throw UsageIssue.cancelled
        }
        sessions.append(session)
    }
    public func cancel() {
        lock.lock()
        cancelled = true
        let active = sessions
        lock.unlock()
        for session in active { session.requestStop() }
    }
    public func finish() {
        lock.lock()
        let active = sessions
        sessions.removeAll()
        lock.unlock()
        for session in active { session.stop() }
    }
}

public final class LineProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var cancelled = false
    private var pid: pid_t = 0
    private var input: Int32 = -1
    private var output: Int32 = -1
    private var errors: Int32 = -1
    private var buffer = Data()
    private var totalBytes = 0
    private let deadline: Date
    private let maximum: Int
    public var processID: Int32 { pid }

    public init(
        executable: String, arguments: [String], environment: [String: String], directory: String,
        timeout: TimeInterval = 25, maximumOutput: Int = 2_097_152
    ) throws {
        deadline = Date().addingTimeInterval(timeout)
        maximum = maximumOutput
        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            for fd in inPipe + outPipe + errPipe where fd >= 0 { Darwin.close(fd) }
            throw UsageIssue.launchFailed
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        for fd in inPipe + outPipe + errPipe { posix_spawn_file_actions_addclose(&actions, fd) }
        let cwdResult = directory.withCString { posix_spawn_file_actions_addchdir(&actions, $0) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        let result =
            cwdResult == 0
            ? argv.withUnsafeBufferPointer { args in
                envp.withUnsafeBufferPointer { env in
                    executable.withCString {
                        posix_spawn(&pid, $0, &actions, &attributes, args.baseAddress!, env.baseAddress!)
                    }
                }
            } : cwdResult
        Darwin.close(inPipe[0])
        Darwin.close(outPipe[1])
        Darwin.close(errPipe[1])
        guard result == 0 else {
            pid = 0
            Darwin.close(inPipe[1])
            Darwin.close(outPipe[0])
            Darwin.close(errPipe[0])
            throw UsageIssue.launchFailed
        }
        input = inPipe[1]
        output = outPipe[0]
        errors = errPipe[0]
        for fd in [input, output, errors] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
    }

    private func check() throws {
        lock.lock()
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { throw UsageIssue.cancelled }
        if Date() >= deadline { throw UsageIssue.timeout }
    }

    public func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(10)
        var written = 0
        while written < data.count {
            try check()
            let n = data.withUnsafeBytes {
                Darwin.write(input, $0.baseAddress!.advanced(by: written), data.count - written)
            }
            if n > 0 {
                written += n
            } else if errno == EAGAIN || errno == EINTR {
                var fd = pollfd(fd: input, events: Int16(POLLOUT), revents: 0)
                _ = poll(&fd, 1, 50)
            } else {
                throw UsageIssue.helperExited
            }
        }
    }

    public func line() throws -> Data {
        while true {
            try check()
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { return line }
            }
            var fds = [
                pollfd(fd: output, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: errors, events: Int16(POLLIN | POLLHUP), revents: 0),
            ]
            let ready = poll(&fds, 2, 50)
            if ready < 0 && errno != EINTR { throw UsageIssue.helperExited }
            for i in 0..<2 where fds[i].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(fds[i].fd, &bytes, bytes.count)
                if count > 0 {
                    totalBytes += count
                    guard totalBytes <= maximum else { throw UsageIssue.outputLimit }
                    if i == 0 { buffer.append(contentsOf: bytes.prefix(count)) }
                    // stderr is drained and discarded, never logged or retained.
                } else if count == 0 {
                    if i == 0 {
                        if !buffer.isEmpty {
                            let last = buffer
                            buffer.removeAll()
                            return last
                        }
                        throw UsageIssue.helperExited
                    }
                    Darwin.close(errors)
                    errors = -1
                }
            }
        }
    }

    public func json() throws -> [String: Any] {
        let data = try line()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageIssue.malformed
        }
        return object
    }

    public func capture() throws -> Data {
        var result = Data()
        do {
            while true {
                result.append(try line())
                result.append(10)
            }
        } catch UsageIssue.helperExited { return result }
    }

    public func requestStop() {
        lock.lock()
        cancelled = true
        if !stopped, pid > 0 { _ = kill(-pid, SIGTERM) }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        guard pid > 0 else { return }
        if input >= 0 {
            Darwin.close(input)
            input = -1
        }
        _ = kill(-pid, SIGTERM)
        // Do not reap the group leader until all group members have been signalled.
        usleep(100_000)
        _ = kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        if output >= 0 {
            Darwin.close(output)
            output = -1
        }
        if errors >= 0 {
            Darwin.close(errors)
            errors = -1
        }
    }
    deinit { stop() }
}
