import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct InstalledApp: Identifiable, Sendable {
    public let bundleID: String
    public let name: String
    public let version: String
    public let build: String?
    public let storeID: Int64?
    public let externalVersionID: Int64?
    public let installManifestURL: URL?
    public let appGroupIDs: [String]
    public var id: String { bundleID }

    public init(bundleID: String, name: String, version: String, build: String? = nil,
                storeID: Int64? = nil, externalVersionID: Int64? = nil, installManifestURL: URL? = nil,
                appGroupIDs: [String] = []) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.build = build
        self.storeID = storeID
        self.externalVersionID = externalVersionID
        self.installManifestURL = installManifestURL
        self.appGroupIDs = appGroupIDs
    }

    public static func validBundleID(_ value: String) -> Bool {
        value.utf8.count <= 255 &&
            value.range(of: "^[A-Za-z0-9][A-Za-z0-9-]*(?:\\.[A-Za-z0-9-]+)*\\z", options: .regularExpression) != nil
    }
}

public struct SavedApp: Codable, Identifiable, Sendable {
    public let bundleID: String
    public let name: String
    public let version: String
    public let build: String
    public let digest: FileDigest
    public let savedAt: Date
    public var id: String { digest.sha256 }
}

public struct StoreApp: Decodable, Identifiable, Sendable {
    public let id: Int64
    public let bundleID: String
    public let name: String
    public let version: String
}

public enum AppDownload: Sendable {
    case fromStore(StoreApp)
    case installedVersion(InstalledApp, Device)

    public var name: String {
        switch self {
        case .fromStore(let app): return app.name
        case .installedVersion(let app, _): return app.name
        }
    }
}

public struct AppBatchResult: Sendable {
    public fileprivate(set) var completed: [SavedApp] = []
    public fileprivate(set) var failures: [String] = []
}

public struct AppLibrary {
    private struct StorePackageIdentity: Equatable {
        let itemID: UInt64
        let versionID: UInt64
        let account: String
    }

    public let root: URL
    private let runner: CommandRunning

    public init(root: URL, runner: CommandRunning = ProcessRunner()) {
        self.root = root
        self.runner = runner
    }

    public func entries() throws -> [SavedApp] {
        try Files.privateDirectory(root)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { Self.validDigest($0.lastPathComponent) }
            .map { folder in
                _ = try SafeFolder(folder)
                let app = try Files.readJSON(SavedApp.self, at: folder.appendingPathComponent("app.json"))
                guard app.id == folder.lastPathComponent, InstalledApp.validBundleID(app.bundleID) else {
                    throw DeskError.invalid("Повреждена запись библиотеки приложений.")
                }
                return app
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    public func importPackage(_ url: URL, expectedBundleID: String? = nil,
                              cancellation: CancellationToken? = nil) throws -> SavedApp {
        try savePackage(url, expectedBundleID: expectedBundleID, expectedVersion: nil, expectedBuild: nil,
                        fromStore: false, cancellation: cancellation)
    }

    private func savePackage(_ url: URL, expectedBundleID: String?, expectedVersion: String?, expectedBuild: String?,
                             fromStore: Bool, cancellation: CancellationToken?) throws -> SavedApp {
        guard url.isFileURL, url.pathExtension.lowercased() == "ipa" else {
            throw DeskError.invalid("Выберите файл .ipa.")
        }
        try Files.privateDirectory(root)
        let lock = try DirectoryLock(directory: root)
        defer { withExtendedLifetime(lock) {} }
        let staging = root.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try Files.privateDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        // Open only the selected file. Opening its parent would request broader macOS file access.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw DeskError.io("Не удалось открыть выбранный IPA.") }
        let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? source.close() }
        var statInfo = stat()
        guard fstat(fd, &statInfo) == 0, (statInfo.st_mode & S_IFMT) == S_IFREG else {
            throw DeskError.invalid("Выберите обычный файл IPA.")
        }
        let output = try SafeFolder(staging).createExclusive("app.ipa")
        defer { try? output.close() }
        while let chunk = try source.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try cancellation?.check()
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        try output.close()

        let package = staging.appendingPathComponent("app.ipa")
        let info = try packageInfo(package, cancellation: cancellation)
        guard let bundleID = info["CFBundleIdentifier"] as? String,
              InstalledApp.validBundleID(bundleID), expectedBundleID == nil || expectedBundleID == bundleID,
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty else {
            throw DeskError.invalid("Манифест пакета не соответствует выбранному приложению.")
        }
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        guard expectedVersion == nil || expectedVersion == version,
              expectedBuild == nil || expectedBuild == build else {
            throw DeskError.unavailable("Получен IPA версии \(version), сборка \(build). На iPhone установлена версия \(expectedVersion ?? "—"), сборка \(expectedBuild ?? "—"). IPA не добавлен в библиотеку.")
        }
        let digest = try Hashing.file(in: SafeFolder(staging), path: "app.ipa", cancellation: cancellation)
        let app = SavedApp(bundleID: bundleID,
                           name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID,
                           version: version, build: build,
                           digest: digest, savedAt: Date())
        let destination = root.appendingPathComponent(app.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try Files.readJSON(SavedApp.self, at: destination.appendingPathComponent("app.json"))
            guard existing.id == app.id, existing.bundleID == app.bundleID else {
                throw DeskError.invalid("Повреждена запись существующего пакета.")
            }
            _ = try verifiedPackage(existing, cancellation: cancellation)
            return existing
        }
        if fromStore, let identity = storeIdentity(in: package, bundleID: bundleID, cancellation: cancellation) {
            let matchingBuilds = try entries().filter { $0.bundleID == bundleID && $0.version == version && $0.build == build }
            for existing in matchingBuilds {
                try cancellation?.check()
                guard let existingPackage = try? verifiedPackage(existing, cancellation: cancellation),
                      storeIdentity(in: existingPackage, bundleID: bundleID, cancellation: cancellation) == identity else { continue }
                return existing
            }
        }
        try Files.writeNewJSON(app, to: staging.appendingPathComponent("app.json"))
        try cancellation?.check()
        try FileManager.default.moveItem(at: staging, to: destination)
        return app
    }

    #if os(macOS)
    public func trashPackage(_ app: SavedApp, cancellation: CancellationToken? = nil) throws {
        guard Self.validDigest(app.id) else { throw DeskError.invalid("Недопустимый идентификатор пакета.") }
        _ = try SafeFolder(root)
        let lock = try DirectoryLock(directory: root)
        defer { withExtendedLifetime(lock) {} }
        let folder = try SafeFolder(root.appendingPathComponent(app.id, isDirectory: true))
        let stored = try Files.readJSON(SavedApp.self, at: folder.url.appendingPathComponent("app.json"))
        guard stored.id == app.id, stored.bundleID == app.bundleID else {
            throw DeskError.invalid("Запись библиотеки изменилась. Обновите список приложений.")
        }
        try cancellation?.check()
        try FileManager.default.trashItem(at: folder.url, resultingItemURL: nil)
    }

    public func trashPackages(_ apps: [SavedApp], cancellation: CancellationToken,
                              progress: (Int, String) -> Void) -> AppBatchResult {
        runBatch(apps, name: \.name, cancellation: cancellation, progress: progress) { app in
            try trashPackage(app, cancellation: cancellation)
            return app
        }
    }
    #endif

    public func copyApp(_ installed: InstalledApp, tool: URL?, cancellation: CancellationToken? = nil) throws -> SavedApp {
        guard !installed.version.isEmpty, installed.version != "—" else {
            throw DeskError.unavailable("iPhone не сообщил версию выбранного приложения.")
        }
        if let saved = try entries().first(where: {
            $0.bundleID == installed.bundleID && $0.version == installed.version &&
                (installed.build == nil || $0.build == installed.build)
        }) {
            _ = try verifiedPackage(saved, cancellation: cancellation)
            return saved
        }
        if installed.storeID == nil, let manifest = installed.installManifestURL {
            return try downloadFromInstaller(installed, manifest: manifest, cancellation: cancellation)
        }
        return try downloadPackage(bundleID: installed.bundleID, storeID: installed.storeID,
                                   externalVersionID: installed.externalVersionID,
                                   expectedVersion: installed.version, expectedBuild: installed.build,
                                   tool: tool, cancellation: cancellation)
    }

    private func downloadFromInstaller(_ app: InstalledApp, manifest: URL, cancellation: CancellationToken?) throws -> SavedApp {
        guard let origin = Self.downloadHost(manifest) else { throw DeskError.invalid("Недопустимый HTTPS-адрес установщика.") }
        try Files.privateDirectory(root)
        let temporary = root.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        try Files.privateDirectory(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let manifestFile = temporary.appendingPathComponent("manifest.plist")
        let limit = 1_048_576
        try fetchInstallerFile(from: manifest, to: manifestFile, limit: UInt64(limit), timeout: 30, cancellation: cancellation)
        let data = try SafeFolder(temporary).data("manifest.plist", maxBytes: limit)
        let plist = try Plists.dictionary(data)
        let items = (plist["items"] as? [[String: Any]] ?? []).filter {
            ($0["metadata"] as? [String: Any])?["bundle-identifier"] as? String == app.bundleID
        }
        let assets = items.flatMap { $0["assets"] as? [[String: Any]] ?? [] }
            .filter { ($0["kind"] as? String) == "software-package" }
        guard assets.count == 1, let address = assets.first?["url"] as? String,
              let ipaURL = URL(string: address), Self.downloadHost(ipaURL) == origin else {
            throw DeskError.unavailable("Установщик не предоставил один IPA выбранного приложения на своём HTTPS-сервере.")
        }
        let maxBytes = try Files.freeBytes(temporary) / 2
        guard maxBytes > 0 else { throw DeskError.unavailable("На Mac недостаточно места для загрузки IPA.") }
        let ipa = temporary.appendingPathComponent("download.ipa")
        try fetchInstallerFile(from: ipaURL, to: ipa, limit: maxBytes, timeout: 1800, cancellation: cancellation)
        return try savePackage(ipa, expectedBundleID: app.bundleID, expectedVersion: app.version,
                               expectedBuild: app.build, fromStore: false, cancellation: cancellation)
    }

    private static func downloadHost(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(),
              host.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$"#,
                         options: .regularExpression) != nil else { return nil }
        let localSuffixes = [".local", ".localhost", ".internal", ".test", ".home.arpa"]
        return localSuffixes.contains(where: host.hasSuffix) ? nil : host
    }

    private func fetchInstallerFile(from url: URL, to file: URL, limit: UInt64, timeout: Int,
                                    cancellation: CancellationToken?) throws {
        let request = CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
            "-q", "--fail", "--silent", "--proto", "=https", "--connect-timeout", "15",
            "--max-time", String(timeout), "--max-filesize", String(limit),
            "--write-out", "%{http_code}", "--output", file.path, "--url", url.absoluteString
        ], timeout: TimeInterval(timeout + 5))
        let result = try runner.run(request, cancellation: cancellation, guardCheck: nil)
        guard result.exitCode == 0, let status = Int(result.output), (200...299).contains(status) else {
            if result.exitCode == 63 { throw DeskError.unavailable("Файл установщика превышает допустимый размер.") }
            throw DeskError.unavailable("Сервер установщика не выдал файл.")
        }
    }

    public func copyApps(_ apps: [InstalledApp], from device: Device, service: DeviceService = DeviceService(),
                         tool: URL?, cancellation: CancellationToken, progress: (Int, String) -> Void) -> AppBatchResult {
        downloadApps(apps.map { .installedVersion($0, device) }, tool: tool, service: service,
                     cancellation: cancellation, progress: progress)
    }

    public func downloadApps(_ apps: [AppDownload], tool: URL?, service: DeviceService = DeviceService(),
                             cancellation: CancellationToken, progress: (Int, String) -> Void) -> AppBatchResult {
        runBatch(apps, name: \.name, cancellation: cancellation, progress: progress) { app in
            switch app {
            case .fromStore(let storeApp):
                return try downloadStoreApp(storeApp, tool: tool, cancellation: cancellation)
            case .installedVersion(let installed, let device):
                let current = try service.installedAppForCopy(installed, on: device, token: cancellation)
                return try copyApp(current, tool: tool, cancellation: cancellation)
            }
        }
    }

    public func installApps(_ apps: [SavedApp], on device: Device, service: DeviceService = DeviceService(),
                            confirmed: Bool, cancellation: CancellationToken,
                            progress: (Int, String) -> Void) throws -> AppBatchResult {
        guard confirmed else { throw DeskError.invalid("Установка не подтверждена.") }
        guard Set(apps.map(\.bundleID)).count == apps.count else {
            throw DeskError.invalid("Выберите по одному IPA для каждого приложения.")
        }
        return runBatch(apps, name: \.name, cancellation: cancellation, progress: progress) { app in
            try service.installApp(app, from: self, on: device, confirmed: true,
                                   acceptMatchingInstalledApp: true, token: cancellation)
            return app
        }
    }

    private func runBatch<App>(_ apps: [App], name: KeyPath<App, String>, cancellation: CancellationToken,
                               progress: (Int, String) -> Void, work: (App) throws -> SavedApp) -> AppBatchResult {
        var result = AppBatchResult()
        for (index, app) in apps.enumerated() {
            guard !cancellation.isCancelled else { break }
            let label = app[keyPath: name]
            progress(index + 1, label)
            do {
                try cancellation.check()
                result.completed.append(try work(app))
            } catch {
                guard !cancellation.isCancelled else { break }
                result.failures.append("«\(label)» — \(error.localizedDescription)")
            }
        }
        return result
    }

    public func searchStore(_ query: String, tool: URL?, cancellation: CancellationToken? = nil) throws -> [StoreApp] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw DeskError.invalid("Введите название приложения.") }
        let request = CommandRequest(executable: try requireDownloadTool(tool), arguments: [
            "--format", "json", "--non-interactive", "search", "--platform", "iphone",
            "--limit", "25", "--", term
        ], timeout: 45)
        let response = try runner.run(request, cancellation: cancellation, guardCheck: nil)
        guard response.exitCode == 0 else { throw downloadError(response, action: "Поиск в App Store") }
        struct SearchResult: Decodable { let apps: [StoreApp] }
        for stream in [response.stdout, response.stderr] {
            for line in stream.split(separator: 0x0A) {
                if let result = try? JSONDecoder().decode(SearchResult.self, from: Data(line)) {
                    var seen = Set<Int64>()
                    return result.apps.filter { $0.id > 0 && InstalledApp.validBundleID($0.bundleID) && seen.insert($0.id).inserted }
                }
            }
        }
        throw DeskError.command("Движок App Store вернул ответ поиска в неизвестном формате.")
    }

    public func purchasedApps(tool: URL?, cancellation: CancellationToken? = nil) throws -> [StoreApp] {
        let request = CommandRequest(executable: try requireDownloadTool(tool), arguments: [
            "--format", "json", "--non-interactive", "list-purchases", "--platform", "iphone", "--all"
        ], timeout: 90)
        let response = try runner.run(request, cancellation: cancellation, guardCheck: nil)
        guard response.exitCode == 0 else { throw downloadError(response, action: "Чтение покупок App Store") }
        struct Purchases: Decodable { let apps: [StoreApp]; let totalCount: Int }
        for stream in [response.stdout, response.stderr] {
            for line in stream.split(separator: 0x0A) {
                if let result = try? JSONDecoder().decode(Purchases.self, from: Data(line)),
                   result.apps.count == result.totalCount {
                    return result.apps.filter { $0.id > 0 }
                }
            }
        }
        throw DeskError.command("App Store не подтвердил полный список покупок.")
    }

    public func downloadStoreApp(_ app: StoreApp, tool: URL?, cancellation: CancellationToken? = nil) throws -> SavedApp {
        guard app.id > 0 else { throw DeskError.invalid("Некорректный ID приложения в App Store.") }
        return try downloadPackage(bundleID: app.bundleID, storeID: app.id, tool: tool, cancellation: cancellation)
    }

    private func requireDownloadTool(_ tool: URL?) throws -> URL {
        guard let tool else {
            throw DeskError.unavailable("Движок App Store отсутствует в этой сборке RR Device Desk.")
        }
        return tool
    }

    private func downloadPackage(bundleID: String, storeID: Int64?, externalVersionID: Int64? = nil,
                                 expectedVersion: String? = nil, expectedBuild: String? = nil, tool: URL?,
                                 cancellation: CancellationToken?) throws -> SavedApp {
        guard InstalledApp.validBundleID(bundleID) else {
            throw DeskError.invalid("Некорректный Bundle ID приложения.")
        }
        let executable = try requireDownloadTool(tool)
        try Files.privateDirectory(root)
        let temporary = root.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        try Files.privateDirectory(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let package = temporary.appendingPathComponent("download.ipa")
        let selector = storeID.map { ["--app-id", String($0)] } ?? ["--bundle-identifier", bundleID]
        let versionSelector = externalVersionID.map { ["--external-version-id", String($0)] } ?? []
        let request = CommandRequest(executable: executable, arguments:
            ["--format", "json", "--non-interactive", "download", "--platform", "iphone"] +
            selector + versionSelector + ["--output", package.path], timeout: 1800, outputPolicy: .tail)
        let response = try runner.run(request, cancellation: cancellation, guardCheck: nil)
        guard response.exitCode == 0 else { throw downloadError(response, action: "Загрузка из App Store") }
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw DeskError.command("Движок App Store завершился без файла IPA.")
        }
        return try savePackage(package, expectedBundleID: bundleID, expectedVersion: expectedVersion,
                               expectedBuild: expectedBuild, fromStore: true, cancellation: cancellation)
    }

    private func downloadError(_ response: CommandResult, action: String) -> DeskError {
        let detail = (response.errorOutput + "\n" + response.output).lowercased()
        if detail.contains("license") || detail.contains("licence") || detail.contains("not purchased") {
            return .unavailable("Для загрузки нужна лицензия в используемой учётной записи Apple.")
        }
        if detail.contains("not found") && (detail.contains("application") || detail.contains("app not found")) {
            return .unavailable("Приложение недоступно по этому идентификатору в App Store.")
        }
        if detail.contains("authenticate") || detail.contains("password token") || detail.contains("failed to get account") || detail.contains("sign in") {
            return .unavailable("Войдите в Apple Account во вкладке «Обзор» в RR Device Desk.")
        }
        if detail.contains("timeout") || detail.contains("connection reset") || detail.contains("unexpected eof") || detail.contains("no such host") {
            return .command("Связь с App Store прервалась. Повторите попытку.")
        }
        return .command("\(action): движок завершился с кодом \(response.exitCode).")
    }

    public func verifiedPackage(_ app: SavedApp, cancellation: CancellationToken? = nil) throws -> URL {
        guard Self.validDigest(app.id) else { throw DeskError.invalid("Недопустимый идентификатор пакета.") }
        let folder = try SafeFolder(root.appendingPathComponent(app.id, isDirectory: true))
        let actual = try Hashing.file(in: folder, path: "app.ipa", cancellation: cancellation)
        guard actual == app.digest else { throw DeskError.invalid("Пакет в библиотеке изменён. Импортируйте исходный IPA снова.") }
        return folder.url.appendingPathComponent("app.ipa")
    }

    private func storeIdentity(in package: URL, bundleID: String, cancellation: CancellationToken?) -> StorePackageIdentity? {
        let request = CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                                     arguments: ["-p", package.path, "iTunesMetadata.plist"], timeout: 10)
        guard let result = try? runner.run(request, cancellation: cancellation, guardCheck: nil),
              result.exitCode == 0, result.stdout.count <= 512 * 1024,
              let metadata = try? Plists.dictionary(result.stdout),
              metadata["softwareVersionBundleId"] as? String == bundleID,
              let itemID = Plists.unsigned(metadata["itemId"]), itemID > 0,
              let versionID = Plists.unsigned(metadata["softwareVersionExternalIdentifier"]), versionID > 0,
              let account = metadata["userName"] as? String, !account.isEmpty else { return nil }
        return StorePackageIdentity(itemID: itemID, versionID: versionID, account: account)
    }

    private func packageInfo(_ package: URL, cancellation: CancellationToken?) throws -> [String: Any] {
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        let listing = try runner.run(CommandRequest(executable: unzip, arguments: ["-Z", "-1", package.path]),
                                     cancellation: cancellation, guardCheck: nil)
        let manifests = listing.output.split(whereSeparator: \.isNewline).map(String.init).filter {
            let components = $0.split(separator: "/", omittingEmptySubsequences: false)
            return components.count == 3 && components[0] == "Payload" &&
                components[1].count > 4 && components[1].hasSuffix(".app") && components[2] == "Info.plist" &&
                !$0.contains(where: { "*?[]\\".contains($0) })
        }
        guard listing.exitCode == 0, manifests.count == 1 else {
            throw DeskError.invalid("В IPA должен быть один основной Payload/*.app/Info.plist.")
        }
        let manifest = try runner.run(CommandRequest(executable: unzip, arguments: ["-p", package.path, manifests[0]]),
                                      cancellation: cancellation, guardCheck: nil)
        guard manifest.exitCode == 0, manifest.stdout.count <= 1024 * 1024 else {
            throw DeskError.invalid("Не удалось безопасно прочитать манифест IPA.")
        }
        return try Plists.dictionary(manifest.stdout)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil
    }
}
