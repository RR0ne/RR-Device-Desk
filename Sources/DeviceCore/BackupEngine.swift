import Foundation

public struct BackupJob: Codable, Identifiable, Sendable {
    public let id: String
    public let startedAt: Date
    public var finishedAt: Date?
    public let deviceID: String
    public let deviceVersion: String
    public var state: String
    public var verificationScope: String?
    public var errorCategory: String?
}
public struct BackupOutcome: Sendable {
    public let directory: URL
    public let job: BackupJob
    public let integrity: IntegrityReport
}
public final class BackupEngine {
    private let service: DeviceService
    public init(service: DeviceService = DeviceService()) { self.service = service }
    public func create(device: Device, root: URL, allowUnencrypted: Bool, confirmed: Bool,
                       cancellation: CancellationToken = CancellationToken(),
                       progress: ((String) -> Void)? = nil) throws -> BackupOutcome {
        guard confirmed else { throw DeskError.invalid("Создание копии не подтверждено.") }
        try Files.privateDirectory(root)
        let lock = try DirectoryLock(directory: root)
        defer { withExtendedLifetime(lock) {} }
        // A second application instance must not operate on the same device in another destination.
        let deviceLock = try Self.lock(device)
        defer { withExtendedLifetime(deviceLock) {} }
        progress?("Проверка соединения, версии инструментов и свободного места")
        try cancellation.check()
        try service.requireBackupVersion()
        try service.validate(device, token: cancellation)
        let details = try service.details(device, token: cancellation)
        guard let encrypted = details.encryption else { throw DeskError.unavailable("Состояние шифрования неизвестно. Копирование не запущено.") }
        guard encrypted || allowUnencrypted else { throw DeskError.invalid("Шифрование выключено. Включите его или явно разрешите незашифрованную копию.") }
        try SafetyPolicy.checkSpace(free: Files.freeBytes(root), usedBytes: details.usedBytes)
        let id = UUID().uuidString
        let staging = root.appendingPathComponent(".partial-" + id)
        let final = root.appendingPathComponent("Backup-" + id)
        try Files.privateDirectory(staging)
        let dataDirectory = staging.appendingPathComponent("data")
        try Files.privateDirectory(dataDirectory)
        let jobURL = staging.appendingPathComponent("operation.json")
        var job = BackupJob(id: id, startedAt: Date(), finishedAt: nil, deviceID: device.udid,
                            deviceVersion: details.version, state: "running", verificationScope: nil, errorCategory: nil)
        try Files.writeJSON(job, to: jobURL)
        do {
            progress?("Копирование. При запросе разблокируйте iPhone. Процент не оценивается искусственно.")
            try service.performBackup(device, directory: dataDirectory, token: cancellation) {
                guard try Files.freeBytes(staging) >= 512 * 1024 * 1024 else {
                    throw DeskError.io("Свободное место упало ниже защитного резерва 512 MiB. Копирование остановлено.")
                }
            }
            try cancellation.check()
            let backupURL = dataDirectory.appendingPathComponent(device.udid)
            let store = try BackupStore(url: backupURL)
            guard store.metadata.udid.caseInsensitiveCompare(device.udid) == .orderedSame,
                  store.metadata.encrypted == encrypted else {
                throw DeskError.invalid("Устройство или режим шифрования в созданной копии не совпадают с запросом.")
            }
            progress?("Проверка структуры и вычисление SHA-256")
            let report = try BackupIntegrity.baseline(at: backupURL, cancellation: cancellation) { count in
                if count % 100 == 0 { progress?("SHA-256: проверено файлов \(count)") }
            }
            try Files.writeJSON(report, to: staging.appendingPathComponent("integrity.json"))
            job.finishedAt = Date()
            job.state = encrypted ? "completed-opaque-unverified-content" : "completed-structure-checked"
            job.verificationScope = report.scope
            try Files.writeJSON(job, to: jobURL)
            try cancellation.check()
            try FileManager.default.moveItem(at: staging, to: final)
            progress?(encrypted ? "Копия записана. Содержимое зашифрованного манифеста не проверено." : "Копия записана; структура и наличие payload проверены. Восстановление не тестировалось.")
            return BackupOutcome(directory: final, job: job, integrity: report)
        } catch {
            job.finishedAt = Date()
            job.state = cancellation.isCancelled ? "cancelled" : "failed"
            job.errorCategory = String(describing: type(of: error))
            // If even writing the outcome fails, the persisted 'running' state remains explicitly unresolved.
            do { try Files.writeJSON(job, to: jobURL) }
            catch { throw DeskError.io("Операция прервана, а журнал результата записать не удалось. Папка .partial сохранена; результат неизвестен.") }
            throw error
        }
    }
    private static func lock(_ device: Device) throws -> DirectoryLock {
        let lockRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rrdevicedesk-locks")
        try Files.privateDirectory(lockRoot)
        return try DirectoryLock(directory: lockRoot, name: device.udid + ".lock")
    }

    func captureAppDataSnapshot(device: Device, in staging: URL, cancellation: CancellationToken,
                                progress: ((String) -> Void)?) throws -> BackupStore {
        let lock = try Self.lock(device)
        defer { withExtendedLifetime(lock) {} }
        try service.requireBackupVersion()
        try service.validate(device, token: cancellation)
        guard try !service.encryption(device, token: cancellation) else {
            throw DeskError.unavailable("Шифрование копий включено. Экспорт из зашифрованной копии пока недоступен.")
        }
        func checkSpace(_ allowance: UInt64 = 512 * 1024 * 1024) throws {
            guard try Files.freeBytes(staging) >= allowance else {
                throw DeskError.io("На диске недостаточно свободного места для временной копии. Выберите другой диск или готовую копию.")
            }
        }
        try checkSpace(1024 * 1024 * 1024)
        progress?("Создаём временную копию iPhone. Если появится запрос, введите код на iPhone.")
        try service.performBackup(device, directory: staging, token: cancellation) { try checkSpace() }
        try cancellation.check()
        return try BackupStore(url: staging.appendingPathComponent(device.udid, isDirectory: true))
    }
    public static func history(root: URL) throws -> [BackupJob] {
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var jobs: [BackupJob] = []
        for child in children where child.lastPathComponent.hasPrefix("Backup-") || child.lastPathComponent.hasPrefix(".partial-") {
            // A damaged journal is not silently dropped from history.
            var job = try Files.readJSON(BackupJob.self, at: child.appendingPathComponent("operation.json"))
            if job.state == "running" { job.state = "interrupted-or-still-running-unknown" }
            if child.lastPathComponent.hasPrefix(".partial-"), job.state.hasPrefix("completed-") {
                job.state = "promotion-not-confirmed"
            }
            jobs.append(job)
        }
        return jobs.sorted { $0.startedAt > $1.startedAt }
    }
}
