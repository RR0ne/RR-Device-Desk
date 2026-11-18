import Foundation

#if os(macOS)
import CryptoKit
import Darwin

public enum AppDataSource: Sendable {
    case existingBackup(URL)
    case newTemporaryBackup
}

public struct AppDataExportResult: Sendable {
    public fileprivate(set) var archives: [URL] = []
    public fileprivate(set) var failures: [String] = []
}

public struct AppDataExporter {
    private let service: DeviceService
    private let runner: CommandRunning

    public init(service: DeviceService = DeviceService(), runner: CommandRunning = ProcessRunner()) {
        self.service = service
        self.runner = runner
    }

    public func export(_ apps: [InstalledApp], for device: Device, from source: AppDataSource, to directory: URL,
                       cancellation: CancellationToken = CancellationToken(),
                       progress: ((String) -> Void)? = nil) throws -> AppDataExportResult {
        guard !apps.isEmpty, Set(apps.map(\.bundleID)).count == apps.count,
              apps.allSatisfy({ InstalledApp.validBundleID($0.bundleID) }) else {
            throw DeskError.invalid("Выберите приложения с корректными Bundle ID.")
        }
        try cancellation.check()
        let existing: BackupStore?
        switch source {
        case .existingBackup(let url):
            let choices = [url, url.appendingPathComponent(device.udid), url.appendingPathComponent("data/" + device.udid)]
            let backup = choices.first {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("Manifest.db").path)
            } ?? url
            let store = try BackupStore(url: backup)
            guard !Files.isInside(directory, root: store.folder.url) else {
                throw DeskError.invalid("Выберите папку для экспорта вне исходной резервной копии.")
            }
            try validate(store, for: device)
            existing = store
        case .newTemporaryBackup:
            existing = nil
        }

        _ = try SafeFolder(directory)
        let staging = directory.appendingPathComponent(".rr-appdata-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }

        let store: BackupStore
        let selection: [InstalledApp]
        if let existing {
            store = existing
            selection = apps
        } else {
            progress?("Проверяем выбранные приложения на iPhone.")
            let current = try service.installedApps(device, token: cancellation)
            let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.bundleID, $0) })
            selection = try apps.map { app in
                guard let live = byID[app.bundleID], live.version == app.version, live.build == app.build else {
                    throw DeskError.unavailable("«\(app.name)» обновилось или исчезло с iPhone. Обновите список приложений.")
                }
                return live
            }
            let backupRoot = staging.appendingPathComponent("snapshot", isDirectory: true)
            try Files.privateDirectory(backupRoot)
            store = try BackupEngine(service: service).captureAppDataSnapshot(device: device, in: backupRoot,
                                                                              cancellation: cancellation, progress: progress)
            try validate(store, for: device)
        }

        var result = AppDataExportResult()
        for (index, app) in selection.enumerated() {
            if cancellation.isCancelled { break }
            progress?("Сохраняем данные \(index + 1) из \(selection.count) · \(app.name)")
            do {
                let archive = try archive(app, in: store, staging: staging, destination: directory,
                                          fresh: existing == nil, cancellation: cancellation)
                result.archives.append(archive)
            } catch {
                if cancellation.isCancelled { break }
                result.failures.append("«\(app.name)» · \(error.localizedDescription)")
            }
        }
        if result.archives.isEmpty { try cancellation.check() }
        return result
    }

    private func validate(_ backup: BackupStore, for device: Device) throws {
        guard backup.metadata.udid.caseInsensitiveCompare(device.udid) == .orderedSame else {
            throw DeskError.invalid("Выбранная резервная копия относится к другому iPhone.")
        }
        guard !backup.metadata.encrypted else {
            throw DeskError.unavailable("Экспорт данных из зашифрованной резервной копии пока недоступен.")
        }
    }

    private struct Metadata: Encodable {
        let formatVersion = 1
        let bundleID: String
        let name: String
        let appVersion: String?
        let appBuild: String?
        let backupDate: Date?
        let iOSVersion: String
        let exportedAt: Date
        let domains: [String]
        let fileCount: Int
    }

    private func archive(_ app: InstalledApp, in store: BackupStore, staging: URL, destination: URL,
                         fresh: Bool, cancellation: CancellationToken) throws -> URL {
        let fm = FileManager.default
        let id = UUID().uuidString.lowercased()
        let contents = staging.appendingPathComponent(id, isDirectory: true)
        let zip = staging.appendingPathComponent(id + ".zip")
        try Files.privateDirectory(contents)
        defer {
            try? fm.removeItem(at: contents)
            try? fm.removeItem(at: zip)
        }
        let groups = Set(app.appGroupIDs.filter(InstalledApp.validBundleID)).sorted()
        let domains = [("AppDomain-" + app.bundleID, "Container")] +
            groups.map { ("AppDomainGroup-" + $0, "AppGroups/" + $0) }
        var includedDomains: [String] = []
        var fileCount = 0
        for (domain, relativeFolder) in domains {
            let output = contents.appendingPathComponent(relativeFolder, isDirectory: true)
            let startCount = fileCount
            try store.forEachAppDataEntry(domain: domain) { entry in
                try cancellation.check()
                guard entry.flags != 4 else { return }
                let expectedID = Insecure.SHA1.hash(data: Data((domain + "-" + entry.relativePath).utf8))
                    .map { String(format: "%02x", $0) }.joined()
                guard expectedID == entry.fileID.lowercased() else {
                    throw DeskError.invalid("Запись в Manifest.db не соответствует домену и пути файла.")
                }
                let target = entry.relativePath.isEmpty ? output : output.appendingPathComponent(entry.relativePath)
                if entry.isFile {
                    try Files.privateDirectory(target.deletingLastPathComponent())
                    _ = try store.export(id: entry.fileID, to: target, cancellation: cancellation)
                    fileCount += 1
                } else {
                    try Files.privateDirectory(target)
                }
            }
            if fileCount > startCount { includedDomains.append(domain) }
        }
        guard fileCount > 0 else {
            throw DeskError.unavailable("В резервной копии нет файлов данных этого приложения.")
        }
        try Files.writeNewJSON(Metadata(bundleID: app.bundleID, name: app.name,
                                       appVersion: fresh && app.version != "—" ? app.version : nil,
                                       appBuild: fresh ? app.build : nil, backupDate: store.snapshotDate,
                                       iOSVersion: store.metadata.version, exportedAt: Date(),
                                       domains: includedDomains, fileCount: fileCount),
                               to: contents.appendingPathComponent("manifest.json"))
        let pack = CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                                  arguments: ["-c", "-k", "--norsrc", contents.path, zip.path],
                                  timeout: 2 * 60 * 60, outputPolicy: .tail)
        guard try runner.run(pack, cancellation: cancellation, guardCheck: nil).exitCode == 0 else {
            throw DeskError.io("Не удалось собрать ZIP с данными приложения.")
        }
        let verify = CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                                    arguments: ["-tqq", zip.path], timeout: 2 * 60 * 60, outputPolicy: .tail)
        guard try runner.run(verify, cancellation: cancellation, guardCheck: nil).exitCode == 0 else {
            throw DeskError.io("ZIP с данными приложения не прошёл проверку.")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zip.path)
        try cancellation.check()
        let name = "\(app.bundleID.prefix(140))-\(id)-data.zip"
        let result = destination.appendingPathComponent(name)
        guard link(zip.path, result.path) == 0 else {
            throw DeskError.io("Не удалось сохранить архив без перезаписи. Выберите папку на диске APFS.")
        }
        return result
    }
}
#endif
