import Darwin
import Foundation

/** A managed executable accepted by the low-level script process boundary. */
struct ScriptCommand: Equatable, Hashable, Sendable {
    let fileURL: URL
}

/** How a script invocation reached its terminal state. */
enum ScriptTermination: Equatable, Sendable {
    case exited(Int32)
    case failed(String)

    var exitCode: Int32 {
        switch self {
        case .exited(let exitCode):
            exitCode
        case .failed:
            -1
        }
    }
}

/** Canonical facts produced by one script process invocation. */
struct ScriptExecutionResult: Sendable {
    let output: String
    let termination: ScriptTermination
    let startedAt: Date
    let duration: TimeInterval

    init(
        output: String,
        termination: ScriptTermination,
        startedAt: Date = Date(),
        duration: TimeInterval = 0
    ) {
        self.output = output
        self.termination = termination
        self.startedAt = startedAt
        self.duration = duration
    }

    init(
        output: String,
        exitCode: Int32,
        startedAt: Date = Date(),
        duration: TimeInterval = 0
    ) {
        self.init(
            output: output,
            termination: exitCode == -1 ? .failed(output) : .exited(exitCode),
            startedAt: startedAt,
            duration: duration
        )
    }

    var exitCode: Int32 { termination.exitCode }
    var succeeded: Bool { termination == .exited(0) }

    private var trimmedOutput: String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var detailText: String {
        if !trimmedOutput.isEmpty {
            return succeeded ? trimmedOutput : "\(trimmedOutput)\n\n[Exit code: \(exitCode)]"
        }

        return succeeded ? "(No output)" : "Script failed with exit code \(exitCode)"
    }

    private var overlaySource: String? {
        if !trimmedOutput.isEmpty {
            return trimmedOutput
        }

        return succeeded ? nil : "Script failed with exit code \(exitCode)"
    }

    func subtitleText(maxLines: Int = 6, maxLength: Int = 480) -> String? {
        guard let overlaySource else { return nil }

        let lines =
            overlaySource
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var result = Array(lines.suffix(maxLines)).joined(separator: "\n")

        guard !result.isEmpty else { return nil }

        if result.count > maxLength {
            result = "…" + String(result.suffix(maxLength - 1))
        }

        return result
    }
}

/** Stateless, injectable owner of script process setup, output capture, and termination. */
struct ScriptRunner: Sendable {
    private let operation: @Sendable (ScriptCommand) async -> ScriptExecutionResult

    init(operation: @escaping @Sendable (ScriptCommand) async -> ScriptExecutionResult) {
        self.operation = operation
    }

    func run(_ command: ScriptCommand) async -> ScriptExecutionResult {
        await operation(command)
    }

    static let live = process(timeout: 60)

    static func process(timeout: TimeInterval) -> ScriptRunner {
        precondition(timeout > 0 && timeout.isFinite)
        return ScriptRunner { command in
            await withCheckedContinuation { continuation in
                // Blocking process IO must not occupy Swift's cooperative executor.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runProcess(command, timeout: timeout))
                }
            }
        }
    }

    private static func runProcess(_ command: ScriptCommand, timeout: TimeInterval) -> ScriptExecutionResult {
        let startedAt = Date()
        let startedUptime = DispatchTime.now().uptimeNanoseconds
        let elapsed: () -> TimeInterval = {
            TimeInterval(DispatchTime.now().uptimeNanoseconds - startedUptime) / 1_000_000_000
        }

        guard FileManager.default.fileExists(atPath: command.fileURL.path) else {
            return failure(
                "Script file not found: \(command.fileURL.path)",
                startedAt: startedAt,
                duration: elapsed()
            )
        }

        guard let source = try? String(contentsOf: command.fileURL, encoding: .utf8) else {
            return failure(
                "Script is not valid UTF-8: \(command.fileURL.lastPathComponent)",
                startedAt: startedAt,
                duration: elapsed()
            )
        }

        let validation = ScriptShebang.inspect(source)
        guard validation.isValid else {
            return failure(
                validation.message,
                startedAt: startedAt,
                duration: elapsed()
            )
        }

        do {
            let pipe = Pipe()
            defer {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            let pid = try spawn(command, output: pipe)
            var reaped = false
            defer {
                if !reaped {
                    kill(-pid, SIGKILL)
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                }
            }
            try? pipe.fileHandleForWriting.close()
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var data = Data()
            var status: Int32 = 0
            var exited = false
            var reachedEOF = false
            var timedOut = false
            var bytes = [UInt8](repeating: 0, count: 8192)

            // Keep the leader unreaped until cleanup so its process-group ID cannot be reused.
            // The deadline covers inherited output pipes as well as the script itself.
            while !exited || !reachedEOF {
                if elapsed() >= timeout {
                    timedOut = true
                    kill(-pid, SIGKILL)
                    break
                }
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    data.append(contentsOf: bytes.prefix(count))
                } else if count == 0 {
                    reachedEOF = true
                } else if errno != EAGAIN && errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                var info = siginfo_t()
                if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                    exited = info.si_pid == pid
                } else if errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if count <= 0 && (!exited || !reachedEOF) {
                    usleep(10_000)
                }
            }
            if !exited { kill(-pid, SIGKILL) }
            while waitpid(pid, &status, 0) == -1 {
                if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            reaped = true
            var output = String(decoding: data, as: UTF8.self)
            let termination: ScriptTermination
            if timedOut {
                let message = "Script timed out after \(timeout.formatted()) seconds."
                output += output.isEmpty ? message : "\n\n\(message)"
                termination = .failed(message)
            } else {
                let exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                termination = .exited(exitCode)
            }
            return ScriptExecutionResult(
                output: output,
                termination: termination,
                startedAt: startedAt,
                duration: elapsed()
            )
        } catch {
            let message = "Error: \(error.localizedDescription)"
            print("TapTick: Failed to run script: \(error)")
            return ScriptExecutionResult(
                output: message,
                termination: .failed(message),
                startedAt: startedAt,
                duration: elapsed()
            )
        }
    }

    private static func spawn(_ command: ScriptCommand, output: Pipe) throws -> pid_t {
        let executable = command.fileURL
        let directory = executable.deletingLastPathComponent()
        let environment = ScriptExecutionEnvironment.environment
        let stdin = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        defer { try? stdin.close() }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_adddup2(&actions, stdin.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        let directoryError = posix_spawn_file_actions_addchdir(&actions, directory.path)
        guard directoryError == 0 else { throw POSIXError(POSIXErrorCode(rawValue: directoryError) ?? .EIO) }

        let argv = [strdup(executable.path), nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let error = argv.withUnsafeBufferPointer { argv in
            envp.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, executable.path, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        return pid
    }

    private static func failure(
        _ message: String,
        startedAt: Date,
        duration: TimeInterval
    ) -> ScriptExecutionResult {
        ScriptExecutionResult(
            output: message,
            termination: .failed(message),
            startedAt: startedAt,
            duration: duration
        )
    }
}
