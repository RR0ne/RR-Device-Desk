import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func check() throws { if isCancelled { throw DeskError.cancelled } }
}
public enum OutputPolicy { case exact, tail }
public struct CommandRequest {
    public let executable: URL
    public let arguments: [String]
    public let timeout: TimeInterval
    public let secretEnvironment: [String: String]
    public let outputPolicy: OutputPolicy
    public let onStdout: (@Sendable (Data) -> Void)?
    public init(executable: URL, arguments: [String], timeout: TimeInterval = 30, secretEnvironment: [String: String] = [:],
                outputPolicy: OutputPolicy = .exact, onStdout: (@Sendable (Data) -> Void)? = nil) {
        self.executable = executable; self.arguments = arguments; self.timeout = timeout
        self.secretEnvironment = secretEnvironment; self.outputPolicy = outputPolicy
        self.onStdout = onStdout
    }
}
public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let outputTruncated: Bool
    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), outputTruncated: Bool = false) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr; self.outputTruncated = outputTruncated
    }
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}
public protocol CommandRunning {
    func run(_ request: CommandRequest, cancellation: CancellationToken?, guardCheck: (() throws -> Void)?) throws -> CommandResult
}
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    private let policy: OutputPolicy
    private let maximum: Int
    init(policy: OutputPolicy) { self.policy = policy; maximum = policy == .exact ? 16 * 1024 * 1024 : 256 * 1024 }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + chunk.count > maximum { overflow = true }
        if policy == .exact {
            data.append(chunk.prefix(max(0, maximum - data.count)))
        } else {
            data.append(chunk)
            if data.count > maximum { data.removeFirst(data.count - maximum) }
        }
    }
    func result() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (data, overflow) }
}
public final class ProcessRunner: CommandRunning {
    public init() {}

    static var environment: [String: String] {
        ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
         "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "LANG": "C", "LC_ALL": "C"]
    }

    public func run(_ request: CommandRequest, cancellation: CancellationToken? = nil,
                    guardCheck: (() throws -> Void)? = nil) throws -> CommandResult {
        try cancellation?.check()
        guard request.executable.isFileURL, request.executable.path.hasPrefix("/"), request.timeout > 0,
              request.arguments.allSatisfy({ !$0.contains("\0") }) else { throw DeskError.invalid("Недопустимая команда.") }
        let process = Process(), outPipe = Pipe(), errPipe = Pipe()
        process.executableURL = request.executable
        process.arguments = request.arguments
        // No inherited BACKUP_PASSWORD, DYLD_*, proxy, USBMUXD_SOCKET_ADDRESS or shell environment.
        process.environment = Self.environment
        for (key, value) in request.secretEnvironment {
            guard key == "BACKUP_PASSWORD" else { throw DeskError.invalid("Запрещённая переменная окружения.") }
            process.environment?[key] = value
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe; process.standardError = errPipe
        let out = Capture(policy: request.outputPolicy), err = Capture(policy: request.outputPolicy), group = DispatchGroup()
        try process.run()
        for (pipe, capture, observe) in [(outPipe, out, request.onStdout), (errPipe, err, nil)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                if let observe {
                    // A pipe read returns available bytes even when the installer hasn't sent a newline.
                    let descriptor = pipe.fileHandleForReading.fileDescriptor
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    while true {
                        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { break }
                        let data = Data(buffer.prefix(count))
                        capture.append(data)
                        observe(data)
                    }
                } else {
                    while let data = try? pipe.fileHandleForReading.read(upToCount: 65536), !data.isEmpty { capture.append(data) }
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + request.timeout
        var interrupted: Error?
        while process.isRunning {
            do {
                try cancellation?.check()
                if ProcessInfo.processInfo.systemUptime >= deadline { throw DeskError.timeout }
                try guardCheck?()
            } catch { interrupted = error; break }
            Thread.sleep(forTimeInterval: 0.10)
        }
        if interrupted != nil, process.isRunning {
            process.terminate()
            let stop = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < stop { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        // A descendant holding a pipe cannot make the UI wait indefinitely.
        let streamsClosed = group.wait(timeout: .now() + 3) == .success
        try? outPipe.fileHandleForReading.close(); try? errPipe.fileHandleForReading.close()
        if let error = interrupted { throw error }
        try cancellation?.check()
        guard streamsClosed else { throw DeskError.command("Поток вывода процесса не завершился.") }
        let (stdout, largeOut) = out.result(), (stderr, largeErr) = err.result()
        guard request.outputPolicy == .tail || (!largeOut && !largeErr) else { throw DeskError.command("Вывод процесса превысил лимит разбора. Результат не подтверждён.") }
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr, outputTruncated: largeOut || largeErr)
    }
}

public enum Tool: String, CaseIterable, Codable, Sendable {
    case installer = "ideviceinstaller"
    case deviceID = "idevice_id", info = "ideviceinfo", pair = "idevicepair", backup = "idevicebackup2", diagnostics = "idevicediagnostics"
}
public struct ToolStatus: Codable, Sendable, Identifiable {
    public let name: String
    public let path: String?
    public let version: String?
    public let error: String?
    public var id: String { name }
}
public struct Toolchain {
    private let directories: [URL]
    public init(directories: [URL] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { URL(fileURLWithPath: $0) }) {
        self.directories = directories
    }
    public func resolve(_ tool: Tool) throws -> URL {
        for dir in directories {
            let path = dir.appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: path.path) { return path }
        }
        let package = tool == .installer ? "ideviceinstaller" : "libimobiledevice"
        throw DeskError.unavailable("Не найден \(tool.rawValue). Установите \(package) по инструкции README.")
    }
}
public enum Redactor {
    public static func text(_ input: String, secrets: [String] = []) -> String {
        var text = input
        for secret in secrets where !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "[REDACTED]") }
        for pattern in ["(?i)[0-9a-f]{8}-[0-9a-f]{16}", "(?i)\\b[0-9a-f]{40}\\b", "(?im)^(.*(?:password|privatekey|hostid|serialnumber|imei|iccid|token).*)$"] {
            text = text.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return text
    }
}
