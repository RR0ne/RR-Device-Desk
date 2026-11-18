import Foundation

public final class DeviceService {
    private let runner: CommandRunning
    private let tools: Toolchain
    public init(runner: CommandRunning = ProcessRunner(), tools: Toolchain = Toolchain()) {
        self.runner = runner; self.tools = tools
    }
    private func command(_ tool: Tool, _ args: [String], timeout: TimeInterval = 30,
                         token: CancellationToken? = nil, secret: String? = nil,
                         guardCheck: (() throws -> Void)? = nil, outputPolicy: OutputPolicy = .exact,
                         onStdout: (@Sendable (Data) -> Void)? = nil) throws -> CommandResult {
        let request = CommandRequest(executable: try tools.resolve(tool), arguments: args,
                                     timeout: timeout, secretEnvironment: secret.map { ["BACKUP_PASSWORD": $0] } ?? [:],
                                     outputPolicy: outputPolicy, onStdout: onStdout)
        let result = try runner.run(request, cancellation: token, guardCheck: guardCheck)
        guard result.exitCode == 0 else {
            let detail = Redactor.text(String((result.errorOutput + "\n" + result.output).suffix(1800)), secrets: secret.map { [$0] } ?? [])
            throw DeskError.command("\(tool.rawValue): код \(result.exitCode). \(detail)")
        }
        return result
    }
    private func args(_ device: Device) -> [String] {
        ["--udid", device.udid] + (device.transport == .network ? ["--network"] : [])
    }
    public func doctor() -> [ToolStatus] {
        Tool.allCases.map { tool in
            do {
                let url = try tools.resolve(tool)
                let r = try command(tool, ["--version"], timeout: 5)
                return ToolStatus(name: tool.rawValue, path: url.path, version: r.output.trimmingCharacters(in: .whitespacesAndNewlines), error: nil)
            } catch { return ToolStatus(name: tool.rawValue, path: nil, version: nil, error: error.localizedDescription) }
        }
    }
    public func devices(transport: Transport, token: CancellationToken? = nil) throws -> [Device] {
        let output = try command(.deviceID, [transport == .usb ? "--list" : "--network"], token: token).output
        var seen = Set<String>()
        return try output.split(whereSeparator: \.isNewline).compactMap { line in
            let id = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return try Device(udid: id, transport: transport)
        }
    }
    public func validate(_ device: Device, token: CancellationToken? = nil) throws {
        _ = try command(.pair, args(device) + ["validate"], token: token)
    }
    public func pair(_ device: Device, confirmed: Bool, token: CancellationToken? = nil) throws {
        guard confirmed else { throw DeskError.invalid("Нужно подтвердить сопряжение.") }
        guard device.transport == .usb else { throw DeskError.unavailable("Первичное сопряжение iPhone выполняется через USB.") }
        _ = try command(.pair, args(device) + ["pair"], timeout: 60, token: token)
        try validate(device, token: token)
    }
    public func encryption(_ device: Device, token: CancellationToken? = nil) throws -> Bool {
        let data = try command(.info, args(device) + ["--xml", "--domain", "com.apple.mobile.backup", "--key", "WillEncrypt"], token: token).stdout
        guard let result = Plists.bool(try Plists.object(data)) else { throw DeskError.unavailable("Устройство не сообщило состояние шифрования.") }
        return result
    }
    public func details(_ device: Device, token: CancellationToken? = nil) throws -> DeviceDetails {
        let info = try Plists.dictionary(command(.info, args(device) + ["--xml"], token: token).stdout)
        var warnings: [String] = [], encrypted: Bool?, used: UInt64?
        do { encrypted = try encryption(device, token: token) } catch { warnings.append("Шифрование: \(error.localizedDescription)") }
        do {
            let disk = try Plists.dictionary(command(.info, args(device) + ["--xml", "--domain", "com.apple.disk_usage"], token: token).stdout)
            if let capacity = Plists.unsigned(disk["TotalDataCapacity"]), let available = Plists.unsigned(disk["TotalDataAvailable"]), capacity >= available {
                used = capacity - available
            } else { warnings.append("Объём данных устройства недоступен.") }
        } catch { warnings.append("Хранилище: \(error.localizedDescription)") }
        try token?.check()
        return DeviceDetails(name: info["DeviceName"] as? String ?? "Apple device", product: info["ProductType"] as? String ?? "неизвестно",
                             version: info["ProductVersion"] as? String ?? "неизвестно", build: info["BuildVersion"] as? String ?? "неизвестно",
                             encryption: encrypted, usedBytes: used, warnings: warnings)
    }
    public func enableEncryption(_ device: Device, password: String, confirmed: Bool, token: CancellationToken? = nil) throws {
        guard confirmed, !password.isEmpty, !password.contains("\0") else { throw DeskError.invalid("Нужны пароль и явное подтверждение.") }
        try requireBackupVersion()
        if try encryption(device, token: token) { throw DeskError.invalid("Шифрование уже включено. Пароль не изменён.") }
        _ = try command(.backup, args(device) + ["encryption", "on"], timeout: 180, token: token, secret: password)
        guard try encryption(device, token: token) else { throw DeskError.command("Включение шифрования не подтверждено устройством.") }
    }
    public func battery(_ device: Device, token: CancellationToken? = nil) throws -> String {
        let r = try command(.diagnostics, args(device) + ["diagnostics", "GasGauge"], token: token)
        // Display returned fields only: do not manufacture a battery-health percentage.
        return Redactor.text(r.output)
    }
    public func installedApps(_ device: Device, bundleID: String? = nil,
                              token: CancellationToken? = nil) throws -> [InstalledApp] {
        try listInstalledApps(device, bundleID: bundleID, includeStoreMetadata: false, token: token)
    }

    public func installedAppForCopy(_ selected: InstalledApp, on device: Device,
                                    token: CancellationToken? = nil) throws -> InstalledApp {
        guard let current = try listInstalledApps(device, bundleID: selected.bundleID,
                                                  includeStoreMetadata: true, token: token).first,
              current.bundleID == selected.bundleID,
              current.version == selected.version, current.build == selected.build else {
            throw DeskError.unavailable("Версия приложения на iPhone изменилась или приложение удалено. Обновите список приложений.")
        }
        return current
    }

    private func listInstalledApps(_ device: Device, bundleID: String?, includeStoreMetadata: Bool,
                                   token: CancellationToken?) throws -> [InstalledApp] {
        guard device.transport == .usb else { throw DeskError.unavailable("Подключите iPhone по USB.") }
        var arguments = args(device) + ["list", "--user", "--xml",
                "-a", "CFBundleIdentifier", "-a", "CFBundleDisplayName", "-a", "CFBundleShortVersionString",
                "-a", "CFBundleVersion", "-a", "GroupContainers"]
        if let bundleID {
            guard InstalledApp.validBundleID(bundleID) else { throw DeskError.invalid("Недопустимый Bundle ID.") }
            arguments += ["--bundle-identifier", bundleID]
            if includeStoreMetadata { arguments += ["-a", "iTunesMetadata"] }
        }
        let reply = try command(.installer, arguments, token: token)
        guard let rows = try Plists.object(reply.stdout) as? [[String: Any]] else {
            throw DeskError.invalid("Не удалось разобрать список приложений iPhone.")
        }
        var seen = Set<String>()
        return rows.compactMap { row -> InstalledApp? in
            guard let id = row["CFBundleIdentifier"] as? String,
                  InstalledApp.validBundleID(id), seen.insert(id).inserted else { return nil }
            let name = row["CFBundleDisplayName"] as? String ?? id
            let version = row["CFBundleShortVersionString"] as? String ?? "—"
            let build = row["CFBundleVersion"] as? String
            let metadata = includeStoreMetadata ? Self.storeMetadata(row["iTunesMetadata"], bundleID: id) : nil
            let sameVersion = (metadata?["bundleShortVersionString"] as? String).map { $0 == version } ?? true
            let sameBuild = (metadata?["bundleVersion"] as? String).map { $0 == build } ?? true
            let externalVersionID = sameVersion && sameBuild ? Self.storeIdentifier(metadata?["softwareVersionExternalIdentifier"]) : nil
            let groupIDs = (row["GroupContainers"] as? [String: String])?.keys
                .filter(InstalledApp.validBundleID).sorted() ?? []
            return InstalledApp(bundleID: id, name: name, version: version, build: build,
                                storeID: Self.storeIdentifier(metadata?["itemId"]), externalVersionID: externalVersionID,
                                installManifestURL: Self.installManifestURL(metadata?["enterpriseInstallURL"]),
                                appGroupIDs: groupIDs)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func installManifestURL(_ value: Any?) -> URL? {
        guard let address = value as? String, address.utf8.count <= 8192,
              let parts = URLComponents(string: address), parts.scheme?.lowercased() == "itms-services",
              let items = parts.queryItems, items.first(where: { $0.name == "action" })?.value == "download-manifest",
              let manifest = items.first(where: { $0.name == "url" })?.value else { return nil }
        return URL(string: manifest)
    }

    private static func storeMetadata(_ value: Any?, bundleID: String) -> [String: Any]? {
        let metadata: [String: Any]?
        if let data = value as? Data, data.count <= 512 * 1024 {
            metadata = try? Plists.dictionary(data)
        } else {
            metadata = value as? [String: Any]
        }
        if let declaredID = metadata?["softwareVersionBundleId"] as? String, declaredID != bundleID { return nil }
        return metadata
    }

    private static func storeIdentifier(_ value: Any?) -> Int64? {
        let number = (value as? String).flatMap { Int64($0) }
            ?? Plists.unsigned(value).flatMap { Int64(exactly: $0) }
        guard let number, number > 0 else { return nil }
        return number
    }

    @discardableResult
    public func installApp(_ app: SavedApp, from library: AppLibrary, on device: Device,
                           confirmed: Bool, acceptMatchingInstalledApp: Bool = false,
                           token: CancellationToken? = nil,
                           progress: (@Sendable (AppInstallProgress) -> Void)? = nil) throws -> AppInstallOutcome {
        guard confirmed else { throw DeskError.invalid("Установка не подтверждена.") }
        progress?(.checkingPackage)
        try validate(device, token: token)
        let package = try library.verifiedPackage(app, cancellation: token)
        let existing = try installedApps(device, bundleID: app.bundleID, token: token)
        if !existing.isEmpty {
            if acceptMatchingInstalledApp, app.version != "—", app.build != "—",
               existing.contains(where: { $0.bundleID == app.bundleID && $0.version == app.version && $0.build == app.build }) {
                return .alreadyInstalled
            }
            throw DeskError.invalid("Приложение уже установлено на выбранном iPhone. Замена не выполнялась.")
        }
        let output = progress.map(InstallerProgressReader.init)
        let onStdout: (@Sendable (Data) -> Void)?
        if let output { onStdout = { output.append($0) } } else { onStdout = nil }
        _ = try command(.installer, args(device) + ["--notify-wait", "install", package.path],
                        timeout: 900, token: token, outputPolicy: .tail, onStdout: onStdout)
        progress?(.verifyingOnDevice)
        guard try installedApps(device, bundleID: app.bundleID, token: token).contains(where: {
            $0.bundleID == app.bundleID && (app.version == "—" || $0.version == app.version) &&
                (app.build == "—" || $0.build == app.build)
        }) else {
            throw DeskError.command("iPhone не подтвердил установку выбранной версии и сборки.")
        }
        return .installed
    }

    public func requireBackupVersion() throws {
        let version = try command(.backup, ["--version"], timeout: 5).output
        guard version.range(of: "\\b1\\.4\\.0(?:\\s|$)", options: .regularExpression) != nil else {
            throw DeskError.unavailable("Версия idevicebackup2 не входит в профиль 1.4.0. Операции записи заблокированы до проверки совместимости. Найдено: \(version)")
        }
    }
    func performBackup(_ device: Device, directory: URL, token: CancellationToken?, guardCheck: (() throws -> Void)?) throws {
        // Caller must give an empty, private staging directory, never a user's existing backup.
        _ = try command(.backup, args(device) + ["backup", "--full", directory.path], timeout: 24 * 60 * 60,
                        token: token, guardCheck: guardCheck, outputPolicy: .tail)
    }
}
