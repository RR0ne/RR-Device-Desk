import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct StoreAccount: Sendable {
    public let email: String
}

public struct StoreAuthentication: Sendable {
    private struct Reply: Decodable {
        let success: Bool?
        let email: String?
        let error: String?
        let event: String?
        let httpStatus: Int?

        var account: StoreAccount? {
            guard success == true, let email, !email.isEmpty else { return nil }
            return StoreAccount(email: email)
        }
    }

    public let executable: URL

    public init(executable: URL) { self.executable = executable }

    public func account() throws -> StoreAccount? {
        let (result, reply) = try sessionCommand("info")
        if result.exitCode == 0, let account = reply?.account { return account }
        if Self.accountMissing(reply?.error) { return nil }
        throw Self.failure(reply?.error)
    }

    public func signOut() throws {
        let (result, reply) = try sessionCommand("revoke")
        guard result.exitCode == 0 && reply?.success == true else {
            throw Self.failure(reply?.error)
        }
    }

    public func logIn(cancellation: CancellationToken, credentials: () throws -> (appleID: String, password: String),
                      verificationCode: (Int?) throws -> String) throws -> StoreAccount {
        try cancellation.check()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.environment = ProcessRunner.environment
        process.arguments = ["--format", "json", "auth", "login", "--prepare-first"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        #if canImport(Darwin)
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        try process.run()
        defer {
            try? writer.close()
            try? reader.close()
            if process.isRunning {
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.025)
                }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
        }

        var deadline = ProcessInfo.processInfo.systemUptime + 360
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        var reply: Reply?
        var verificationStatus: Int?
        var password: String?
        var phase = 0
        while true {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DeskError.timeout }
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw DeskError.io("Не удалось прочитать ответ входа.") }
            let count = read(reader.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw DeskError.io("Не удалось прочитать ответ входа.") }
            if count == 0 { break }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 64 * 1024 else { throw DeskError.command("Ответ входа слишком большой.") }

            while let end = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                let value = String(decoding: line, as: UTF8.self)
                switch (phase, value) {
                case (0, "enter Apple ID (email address or phone number):"):
                    let waitingSince = ProcessInfo.processInfo.systemUptime
                    let supplied = try credentials()
                    deadline += ProcessInfo.processInfo.systemUptime - waitingSince
                    try cancellation.check()
                    let forbidden = CharacterSet.newlines.union(CharacterSet(charactersIn: "\0"))
                    guard [supplied.appleID, supplied.password].allSatisfy({
                        !$0.isEmpty && $0.utf8.count <= 1024 && $0.rangeOfCharacter(from: forbidden) == nil
                    }) else { throw DeskError.invalid("Введите Apple Account и пароль в отдельных полях.") }
                    password = supplied.password
                    try writer.write(contentsOf: Data((supplied.appleID + "\n").utf8))
                    phase = 1
                case (1, "enter password:"):
                    guard let enteredPassword = password else { throw DeskError.command("Движок запросил пароль вне последовательности входа.") }
                    try writer.write(contentsOf: Data((enteredPassword + "\n").utf8))
                    password = nil
                    phase = 2
                case (2, "enter 2FA code:"):
                    let waitingSince = ProcessInfo.processInfo.systemUptime
                    let code = try verificationCode(verificationStatus)
                    deadline += ProcessInfo.processInfo.systemUptime - waitingSince
                    try cancellation.check()
                    guard Self.validVerificationCode(code) else { throw DeskError.invalid("Введите шестизначный код Apple.") }
                    try writer.write(contentsOf: Data((code + "\n").utf8))
                    phase = 3
                default:
                    if let event = try? JSONDecoder().decode(Reply.self, from: line) {
                        if event.success != nil { reply = event }
                        if phase == 2, event.event == "verification-fallback",
                           let status = event.httpStatus, (100...599).contains(status) {
                            verificationStatus = status
                        }
                    }
                }
            }
        }
        while process.isRunning {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DeskError.timeout }
            Thread.sleep(forTimeInterval: 0.025)
        }
        try cancellation.check()
        if reply == nil {
            throw DeskError.command("Движок завершил вход без ответа (код \(process.terminationStatus)).")
        }
        guard process.terminationStatus == 0, phase >= 2, let account = reply?.account else {
            throw Self.failure(reply?.error)
        }
        return account
    }

    public static func validVerificationCode(_ code: String) -> Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func sessionCommand(_ command: String) throws -> (CommandResult, Reply?) {
        let result = try ProcessRunner().run(CommandRequest(executable: executable,
            arguments: ["--format", "json", "--non-interactive", "auth", command], timeout: 15))
        let replies = result.stdout.split(separator: 0x0A).compactMap {
            try? JSONDecoder().decode(Reply.self, from: Data($0))
        }
        return (result, replies.last(where: { $0.success != nil }))
    }

    private static func accountMissing(_ error: String?) -> Bool {
        let message = error?.lowercased() ?? ""
        return message.contains("key not found") || message.contains("item could not be found")
    }

    private static func failure(_ error: String?) -> DeskError {
        let message = error?.lowercased() ?? ""
        if message.contains("store session is busy") {
            return .unavailable("Идёт другая операция App Store. Повторите после её завершения.")
        }
        if message.contains("keychain") || message.contains("interaction is not allowed") || message.contains("failed to set item") {
            return .unavailable("Не удалось открыть Связку ключей macOS для RR Device Desk.")
        }
        if message.contains("certificate") || message.contains("x509:") {
            return .unavailable("Не удалось проверить сертификат сервера Apple. Проверьте сеть и дату на Mac.")
        }
        if message.contains("timeout") || message.contains("no such host") || message.contains("connection reset")
            || message.contains("connection refused") || message.contains("network is unreachable") || message.contains("unexpected eof") {
            if message.contains("store authentication bag") || message.contains("get bag:") {
                return .command("Не удалось соединиться с сервером настроек App Store. Проверьте сеть и повторите вход.")
            }
            if message.contains("prepare apple authentication") {
                return .command("Сервер подготовки входа Apple не ответил. Попробуйте другую сеть и повторите вход.")
            }
            return .command("Соединение с Apple прервалось во время входа. Проверьте сеть и повторите попытку.")
        }
        if message.contains("fresh 2fa code") || message.contains("2fa code must") || message.contains("auth code is required") {
            return .unavailable("Apple не подтвердила код. Начните вход заново и введите новый код.")
        }
        if message.contains("account is disabled") || message.contains("account is locked") {
            return .unavailable("Apple сообщила, что учётная запись заблокирована.")
        }
        if message.contains("rate limited") || message.contains("http 429") || message.contains("requested a wait") {
            return .unavailable("Apple ограничила частоту запросов. Повторите вход позже.")
        }
        if message.contains("prepare apple authentication"), message.contains("http 401") {
            let phase = message.contains("finish machine provisioning") ? "завершающий запрос" : "запрос"
            let code = message.range(of: #"(?<=\(apple code )-?[0-9]{1,6}(?=\))"#, options: .regularExpression)
                .map { ", код Apple \(message[$0])" } ?? ""
            return .unavailable("Apple отклонила \(phase) подготовки входа (HTTP 401\(code)). Проверка Apple Account ещё не началась.")
        }
        if let status = [502, 503, 504].first(where: { message.contains("http \($0)") || message.contains("unexpected status code: \($0)") }) {
            return .unavailable("Сервер входа Apple временно недоступен (HTTP \(status)). Повторите вход позже.")
        }
        if message.contains("invalid credential") || message.contains("incorrect password") || message.contains("failuresignin")
            || message.contains("incorrect apple id") || message.contains("apple id or password") {
            return .unavailable("Apple отклонила вход. Проверьте Apple Account, пароль и код подтверждения.")
        }
        if message.contains("no usable authentication response") {
            return .command("Сервер Apple вернул неполный ответ на запрос входа. Повторите попытку позже.")
        }
        if message.contains("prepare apple authentication") {
            return .command("Apple не завершила подготовку входа. Ввод кода подтверждения ещё не начался.")
        }
        return .command("Apple не подтвердила вход. Проверьте данные и повторите попытку.")
    }
}
