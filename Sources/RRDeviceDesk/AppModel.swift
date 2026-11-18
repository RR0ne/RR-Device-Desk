import SwiftUI
import AppKit
import DeviceCore

struct BackupViewData: Sendable {
    let metadata: BackupMetadata
    let entries: [BackupEntry]
}
struct DiagnosticExport: Codable {
    let schema: Int
    let appVersion: String
    let generatedAt: Date
    let hostOS: String
    let deviceInfoLastReadAt: Date?
    let deviceProduct: String?
    let deviceOS: String?
    let deviceBuild: String?
    let tools: [String: String]
    let physicalAcceptanceTests: String
    let restore: String
    let note: String
}
struct AuditRecord: Codable {
    let date: Date
    let action: String
    let state: String
    let errorType: String?
}

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

@MainActor
final class AppModel: ObservableObject {
    @Published var section = "devices"
    @Published var devices: [Device] = []
    @Published var selectedDeviceID: String?
    @Published var details: DeviceDetails?
    @Published var detailsReadAt: Date?
    @Published var transport: Transport = .usb
    @Published var tools: [ToolStatus] = []
    @Published var busy = false
    @Published var status = "Откройте существующую копию или проверьте инструменты."
    @Published var errorMessage: String?
    @Published var auditWarning: String?
    @Published var recentEvents: [String] = []
    @Published var backupRoot: URL?
    @Published var openedBackup: URL?
    @Published var backupMetadata: BackupMetadata?
    @Published var entries: [BackupEntry] = []
    @Published var selectedFileID: String?
    @Published var search = ""
    @Published var page = 0
    @Published var history: [BackupJob] = []
    @Published var batteryOutput = ""
    @Published var allowUnencrypted = false
    @Published var savedApps: [SavedApp] = []
    @Published var appDevices: [Device] = []
    @Published var appDeviceID: String?
    @Published var appsOnDevice: [InstalledApp] = []
    @Published var appListLoaded = false
    @Published var appBatchFailures: [String] = []
    @Published var installQueue = AppInstallQueue()
    @Published var exportedAppData: [URL] = []

    var appDevice: Device? { appDevices.first { $0.id == appDeviceID } }
    private var cancellation: CancellationToken?
    var selectedDevice: Device? { devices.first { $0.id == selectedDeviceID } }
    var selectedEntry: BackupEntry? { entries.first { $0.id == selectedFileID } }

    init() {
        if let path = UserDefaults.standard.string(forKey: "backupRoot") { backupRoot = URL(fileURLWithPath: path) }
    }
    private func audit(_ action: String, state: String, error: Error? = nil) {
        let entry = AuditRecord(date: Date(), action: action, state: state,
                                errorType: error.map { String(describing: type(of: $0)) })
        // No raw device output, passwords, UDIDs, file names, names or messages in this audit trail.
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RRDeviceDesk/Audit")
            try Files.privateDirectory(root)
            try Files.writeJSON(entry, to: root.appendingPathComponent(UUID().uuidString + ".json"))
        } catch { auditWarning = "Журнал недоступен: \(error.localizedDescription)" }
        recentEvents.insert("\(Date().formatted(date: .omitted, time: .standard)) · \(action): \(state)", at: 0)
        if recentEvents.count > 200 { recentEvents.removeLast(recentEvents.count - 200) }
    }
    func perform<T: Sendable>(_ name: String, work: @escaping (CancellationToken) throws -> T,
                              failure: ((Error) -> Void)? = nil,
                              success: @escaping (T) -> Void) {
        guard !busy else { return }
        busy = true; errorMessage = nil; status = name
        let token = CancellationToken(); cancellation = token
        audit(name, state: "started")
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try work(token) }.value
                busy = false; cancellation = nil; status = name + ": завершено"
                audit(name, state: "completed"); success(result)
            } catch {
                busy = false; cancellation = nil
                status = name + ": не подтверждено"
                audit(name, state: token.isCancelled ? "cancelled" : "failed", error: error)
                if let failure { failure(error) } else { errorMessage = error.localizedDescription }
            }
        }
    }
    func cancel() {
        if installQueue.attempt != nil {
            pauseInstallation()
            return
        }
        cancellation?.cancel()
        status = "Останавливаем операцию; частичные файлы сохраняются отдельно."
    }
    func updateOperationStatus(_ message: String, for token: CancellationToken) {
        guard cancellation === token, !token.isCancelled else { return }
        status = message
    }
    func doctor() {
        perform("Проверка инструментов", work: { _ in DeviceService().doctor() }) { self.tools = $0 }
    }
    func scan() {
        let mode = transport
        details = nil; selectedDeviceID = nil; devices = []
        perform("Поиск устройств \(mode.title)", work: { token in try DeviceService().devices(transport: mode, token: token) }) {
            self.devices = $0
            self.status = $0.isEmpty ? "Устройства не найдены. Подключите кабель, разблокируйте iPhone и проверьте доверие." : "Найдено устройств: \($0.count). Выберите нужное."
        }
    }
    func readDevice() {
        details = nil; detailsReadAt = nil; batteryOutput = ""
        guard let d = selectedDevice else { return }
        perform("Чтение информации устройства", work: { token in try DeviceService().details(d, token: token) }) {
            self.details = $0; self.detailsReadAt = Date()
        }
    }
    func pair() {
        guard let d = selectedDevice else { return }
        perform("Сопряжение - подтвердите доверие на iPhone", work: { token in
            try DeviceService().pair(d, confirmed: true, token: token)
            return try DeviceService().details(d, token: token)
        }) { self.details = $0; self.detailsReadAt = Date() }
    }
    func enableEncryption(password: String, remember: Bool) {
        guard let d = selectedDevice else { return }
        perform("Включение шифрования - подтвердите код на iPhone", work: { token in
            try DeviceService().enableEncryption(d, password: password, confirmed: true, token: token)
            if remember { try KeychainStore.save(password: password, deviceID: d.udid) }
            return try DeviceService().details(d, token: token)
        }) { self.details = $0; self.detailsReadAt = Date() }
    }
    func battery() {
        guard let d = selectedDevice else { return }
        perform("Запрос доступных данных аккумулятора", work: { token in try DeviceService().battery(d, token: token) }) { self.batteryOutput = $0 }
    }
    func chooseBackupRoot() {
        guard let url = Self.pickDirectory(message: "Папка для НОВЫХ копий. Старые копии приложение не перезаписывает.") else { return }
        backupRoot = url; UserDefaults.standard.set(url.path, forKey: "backupRoot"); loadHistory()
    }
    func createBackup() {
        guard let d = selectedDevice, let root = backupRoot else { return }
        let allow = allowUnencrypted
        perform("Создание резервной копии", work: { [weak self] token in
            try BackupEngine().create(device: d, root: root, allowUnencrypted: allow, confirmed: true, cancellation: token) { phase in
                Task { @MainActor [weak self] in
                    guard let self, self.cancellation === token else { return }
                    self.status = phase
                }
            }
        }) { result in
            self.status = result.job.state == "completed-structure-checked" ? "Копия записана и структурно проверена; восстановление не тестировалось." : "Копия записана; содержимое зашифрованного манифеста не проверено."
            NSWorkspace.shared.activateFileViewerSelecting([result.directory])
            self.loadHistory()
        }
    }
    func loadHistory() {
        guard let root = backupRoot else { return }
        perform("Чтение истории", work: { _ in try BackupEngine.history(root: root) }) { self.history = $0 }
    }
    func openBackup() {
        guard let url = Self.pickDirectory(message: "Выберите копию: папку, внутри которой находятся Info.plist, Status.plist и Manifest.db.") else { return }
        loadBackup(url: url, page: 0, search: "")
    }
    func loadBackup(url: URL? = nil, page: Int? = nil, search: String? = nil) {
        guard let url = url ?? openedBackup else { return }
        let newPage = page ?? self.page, term = search ?? self.search
        perform("Чтение резервной копии", work: { _ in
            let store = try BackupStore(url: url)
            return BackupViewData(metadata: store.metadata, entries: store.metadata.encrypted ? [] : try store.entries(search: term, offset: newPage * 200))
        }) {
            self.openedBackup = url; self.backupMetadata = $0.metadata; self.entries = $0.entries
            self.page = newPage; self.search = term; self.selectedFileID = nil; self.section = "backups"
        }
    }
    func exportFile() {
        guard let root = openedBackup, let entry = selectedEntry, entry.isFile else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = entry.name; panel.message = "Экспорт файла из копии. Существующий файл никогда не перезаписывается."
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        perform("Экспорт файла", work: { token in try BackupStore(url: root).export(id: entry.fileID, to: dest, cancellation: token) }) {
            self.status = "Файл экспортирован, SHA-256 совпадает: \($0.sha256)"
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        }
    }
    func createBaseline() {
        guard let root = openedBackup else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "integrity-\(UUID().uuidString.prefix(8)).json"
        panel.message = "Сохраните SHA-256 реестр ВНЕ папки исходной копии. Это не тест восстановления."
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        perform("Проверка структуры и SHA-256", work: { token in
            guard !Files.isInside(dest, root: root) else { throw DeskError.invalid("Нельзя писать отчёт внутрь исходной копии.") }
            let report = try BackupIntegrity.baseline(at: root, cancellation: token)
            try Files.writeNewJSON(report, to: dest)
            return report.files.count
        }) { self.status = "SHA-256 реестр сохранён: файлов \($0). Полнота данных телефона и восстановимость не подтверждены." }
    }
    func verifyBaseline() {
        guard let root = openedBackup else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Выберите ранее сохранённый integrity.json именно для этой копии."
        guard panel.runModal() == .OK, let reportURL = panel.url else { return }
        perform("Сверка с прежним SHA-256 реестром", work: { token in
            let report = try Files.readJSON(IntegrityReport.self, at: reportURL)
            try BackupIntegrity.verify(report, at: root, cancellation: token)
            return report.files.count
        }) { self.status = "Совпадают файлов: \($0). Восстановление на устройство не проверялось." }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "rrdevice-diagnostics.json"
        panel.message = "Только версии и статусы проверок. Без UDID, имени телефона, паролей и содержимого данных."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = DiagnosticExport(schema: 1, appVersion: appVersion, generatedAt: Date(), hostOS: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceInfoLastReadAt: detailsReadAt, deviceProduct: details?.product, deviceOS: details?.version, deviceBuild: details?.build,
            tools: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.version ?? "not-available-or-not-probed") }),
            physicalAcceptanceTests: "NOT RUN by this application; device listing is not a compatibility certification",
            restore: "not implemented; blocked", note: "This report describes observations, not iOS 27 certification. No raw device logs are included.")
        perform("Экспорт диагностики", work: { _ in
            try Files.writeNewJSON(snapshot, to: url)
            return true
        }) { _ in self.status = "Диагностика сохранена локально." }
    }
    static func pickDirectory(message: String) -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}
