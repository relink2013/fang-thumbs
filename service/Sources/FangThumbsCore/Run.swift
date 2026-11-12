import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct ToolError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Runs a tool (at lower priority) with a time limit; returns its standard output, or throws with the end of its
/// error output.
///
/// Plain posix_spawn, poll and waitpid: Foundation's Process has crashed under many parallel runs on Linux. Both
/// pipes are drained while the tool runs, so it can't block on a full pipe; a tool past the limit is killed. The
/// pipes are close-on-exec, so tools started in parallel never hold each other's pipes open.
@discardableResult
public func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> Data {
    var outputPipe: [Int32] = [0, 0], errorPipe: [Int32] = [0, 0]
    guard pipe(&outputPipe) == 0, pipe(&errorPipe) == 0 else { throw ToolError("pipe failed") }
    for fd in outputPipe + errorPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    #if canImport(Glibc)
    var actions = posix_spawn_file_actions_t()
    var attributes = posix_spawnattr_t()
    #else
    var actions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    #endif
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }
    #if canImport(Darwin)
    // Every descriptor not named in the file actions is closed in the child.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    #endif
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errorPipe[1], 2)

    let argv = (["nice", "-n", "10", tool] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { environment.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = posix_spawnp(&pid, "nice", &actions, &attributes, argv, environment)
    close(outputPipe[1])
    close(errorPipe[1])
    defer {
        close(outputPipe[0])
        close(errorPipe[0])
    }
    guard spawned == 0 else { throw ToolError("couldn't start \(tool)") }

    var output = Data(), errors = Data()
    var open = [outputPipe[0], errorPipe[0]]
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while !open.isEmpty {
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            throw ToolError("\(tool) took longer than \(Int(timeout)) s")
        }
        var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        guard poll(&fds, nfds_t(fds.count), Int32(min(left, 1) * 1000)) >= 0 else { continue }
        for entry in fds where entry.revents != 0 {
            let count = read(entry.fd, &buffer, buffer.count)
            if count > 0 {
                if entry.fd == outputPipe[0] {
                    output.append(contentsOf: buffer[0..<count])
                } else if errors.count < 64 * 1024 {
                    errors.append(contentsOf: buffer[0..<count])
                }
            } else {
                open.removeAll { $0 == entry.fd }
            }
        }
    }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    guard status == 0 else {
        let message = String(decoding: errors, as: UTF8.self)
        let tail = message.split(separator: "\n").suffix(2).joined(separator: " ")
        throw ToolError("\(tool): " + (tail.isEmpty ? "failed (status \(status))" : tail))
    }
    return output
}

/// True when the tool can be started.
public func toolExists(_ tool: String) -> Bool {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":")
    return paths.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
}
