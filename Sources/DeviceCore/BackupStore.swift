import Foundation
import CSQLite
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct BackupMetadata: Codable, Sendable {
    public let deviceName: String
    public let udid: String
    public let version: String
    public let encrypted: Bool
    public let finished: Bool
}
public struct BackupEntry: Codable, Identifiable, Hashable, Sendable {
    public let fileID: String
    public let domain: String
    public let relativePath: String
    public let flags: Int
    public var id: String { fileID }
    public var name: String { URL(fileURLWithPath: relativePath).lastPathComponent }
    public var isFile: Bool { flags == 1 }
}

/// Read-only SQLite access. Unknown schema, active WAL or encrypted DB => fail closed.
public final class BackupStore {
    public let folder: SafeFolder
    public let metadata: BackupMetadata
    let snapshotDate: Date?
    fileprivate let canonicalURL: URL
    private var db: OpaquePointer?
    public init(url: URL) throws {
        folder = try SafeFolder(url)
        // Use one physical path for SQLite NOFOLLOW and Foundation enumeration.
        // SafeFolder has already rejected symlinks at the selected directory itself.
        guard let resolved = realpath(folder.url.path, nil) else {
            throw DeskError.io("Не удалось определить путь к резервной копии.")
        }
        defer { free(resolved) }
        canonicalURL = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let info = try Plists.dictionary(folder.data("Info.plist"))
        let manifest = try Plists.dictionary(folder.data("Manifest.plist"))
        let status = try Plists.dictionary(folder.data("Status.plist"))
        guard let encrypted = Plists.bool(manifest["IsEncrypted"]),
              let udid = info["Unique Identifier"] as? String, Device.validUDID(udid),
              let state = status["SnapshotState"] as? String else {
            throw DeskError.invalid("Неполная или неизвестная структура резервной копии.")
        }
        metadata = BackupMetadata(deviceName: info["Device Name"] as? String ?? "неизвестно", udid: udid,
                                  version: info["Product Version"] as? String ?? "неизвестно", encrypted: encrypted,
                                  finished: state == "finished")
        snapshotDate = status["Date"] as? Date ?? info["Last Backup Date"] as? Date
        guard metadata.finished else { throw DeskError.invalid("SnapshotState не равен finished. Копия незавершена.") }
        let h = try folder.read("Manifest.db"); try h.close()
        guard !encrypted else { return }
        for suffix in ["-wal", "-journal"] {
            let sidecar = canonicalURL.appendingPathComponent("Manifest.db" + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: sidecar.path)
                if (attrs[.size] as? NSNumber)?.uint64Value ?? 0 > 0 {
                    throw DeskError.invalid("У Manifest.db есть активный WAL/journal. Завершите запись копии перед чтением.")
                }
            }
        }
        let uri = canonicalURL.appendingPathComponent("Manifest.db").absoluteString + "?mode=ro&immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw DeskError.invalid("Не удалось открыть Manifest.db только для чтения.")
        }
        var initialized = false
        defer { if !initialized { if let db { sqlite3_close(db) }; db = nil } }
        // Apple’s system SQLite omits extension loading.
        #if !os(macOS)
        sqlite3_enable_load_extension(db, 0)
        #endif
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 32 * 1024 * 1024)
        guard sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF;", nil, nil, nil) == SQLITE_OK else {
            throw DeskError.invalid("Не удалось включить безопасный режим SQLite.")
        }
        var tableOK = false
        try each("SELECT type FROM sqlite_master WHERE name='Files'") { s in tableOK = self.text(s, 0) == "table" }
        guard tableOK else { throw DeskError.invalid("В Manifest.db отсутствует таблица Files.") }
        var columns = Set<String>()
        try each("PRAGMA table_info(Files)") { s in columns.insert(self.text(s, 1)) }
        guard Set(["fileID", "domain", "relativePath", "flags"]).isSubset(of: columns) else {
            throw DeskError.invalid("Неизвестная схема Manifest.db; чтение остановлено.")
        }
        initialized = true
    }
    deinit { if let db { sqlite3_close(db) } }
    private func requireDB() throws {
        guard db != nil else { throw DeskError.unavailable("Копия зашифрована. В версии 0.1 расшифровка и просмотр её содержимого не реализованы.") }
    }
    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }
    private func each(_ sql: String, bindings: [String] = [], _ body: (OpaquePointer) throws -> Void) throws {
        try requireDB()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let s = statement else {
            throw DeskError.invalid("Ошибка чтения схемы резервной копии.")
        }
        defer { sqlite3_finalize(s) }
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_text(s, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw DeskError.invalid("Ошибка параметров SQLite.") }
        }
        var code = sqlite3_step(s)
        while code == SQLITE_ROW { try body(s); code = sqlite3_step(s) }
        guard code == SQLITE_DONE else { throw DeskError.invalid("SQLite не завершил чтение. Данные могут быть повреждены.") }
    }
    private func entry(_ s: OpaquePointer) throws -> BackupEntry {
        let id = text(s, 0), domain = text(s, 1), path = text(s, 2), flags = Int(sqlite3_column_int(s, 3))
        guard id.range(of: "^[0-9a-fA-F]{40}\\z", options: .regularExpression) != nil,
              domain.range(of: "^[A-Za-z0-9_.-]+\\z", options: .regularExpression) != nil,
              [1, 2, 4].contains(flags) else { throw DeskError.invalid("Недопустимая запись в Manifest.db.") }
        if !path.isEmpty { _ = try SafeFolder.components(path) }
        if flags == 1 && path.isEmpty { throw DeskError.invalid("У файла отсутствует путь.") }
        return BackupEntry(fileID: id, domain: domain, relativePath: path, flags: flags)
    }
    public func entries(search: String = "", offset: Int = 0, limit: Int = 200) throws -> [BackupEntry] {
        guard offset >= 0, limit > 0, limit <= 1000, !search.contains("\0") else { throw DeskError.invalid("Недопустимая страница.") }
        // instr() treats quotes, '%' and '_' literally. No SQL is constructed from user text.
        var result: [BackupEntry] = []
        try each("SELECT fileID,domain,relativePath,flags FROM Files WHERE instr(lower(domain||'/'||relativePath),lower(?))>0 ORDER BY domain,relativePath LIMIT \(limit) OFFSET \(offset)", bindings: [search]) {
            result.append(try self.entry($0))
        }
        return result
    }
    public func file(id: String) throws -> BackupEntry {
        var found: BackupEntry?
        try each("SELECT fileID,domain,relativePath,flags FROM Files WHERE fileID=?", bindings: [id]) {
            guard found == nil else { throw DeskError.invalid("Дублирующий fileID в Manifest.db.") }
            found = try self.entry($0)
        }
        guard let entry = found, entry.isFile else { throw DeskError.invalid("Файл не найден или запись не является обычным файлом.") }
        return entry
    }
    public func forEachFile(_ callback: (BackupEntry) throws -> Void) throws {
        var seen = Set<String>()
        try each("SELECT fileID,domain,relativePath,flags FROM Files ORDER BY fileID") { s in
            let row = try self.entry(s)
            guard seen.insert(row.fileID).inserted else { throw DeskError.invalid("Дублирующий fileID в Manifest.db.") }
            if row.isFile { try callback(row) }
        }
    }
    func forEachAppDataEntry(domain: String, _ callback: (BackupEntry) throws -> Void) throws {
        try each("SELECT fileID,domain,relativePath,flags FROM Files WHERE domain COLLATE BINARY = ? ORDER BY relativePath",
                 bindings: [domain]) { try callback(self.entry($0)) }
    }
    public func checkSQLite() throws {
        var responses: [String] = []
        try each("PRAGMA integrity_check") { responses.append(self.text($0, 0)) }
        guard responses == ["ok"] else { throw DeskError.invalid("SQLite integrity_check обнаружил повреждение.") }
    }
    public func payloadPath(_ entry: BackupEntry) throws -> String {
        let sharded = String(entry.fileID.prefix(2)) + "/" + entry.fileID
        let selected = FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(sharded).path) ? sharded : entry.fileID
        let handle = try folder.read(selected); try handle.close()
        return selected
    }
    @discardableResult
    public func export(id: String, to destination: URL, cancellation: CancellationToken? = nil) throws -> FileDigest {
        guard !Files.isInside(destination, root: folder.url) else { throw DeskError.invalid("Нельзя экспортировать внутрь исходной резервной копии.") }
        let e = try file(id: id), source = try payloadPath(e)
        let targetFolder = try SafeFolder(destination.deletingLastPathComponent())
        _ = try SafeFolder.components(destination.lastPathComponent)
        let tempName = ".rr-export-\(UUID().uuidString).partial"
        let temp = destination.deletingLastPathComponent().appendingPathComponent(tempName)
        let input = try folder.read(source), output = try targetFolder.createExclusive(tempName)
        defer { try? input.close(); try? output.close(); try? FileManager.default.removeItem(at: temp) }
        while true {
            try cancellation?.check()
            let data = try input.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
        }
        try output.synchronize(); try output.close()
        let original = try Hashing.file(in: folder, path: source, cancellation: cancellation)
        let copied = try Hashing.file(in: targetFolder, path: tempName, cancellation: cancellation)
        guard original == copied else { throw DeskError.invalid("Контрольная сумма экспорта не совпала.") }
        // Atomic publish without overwriting a concurrently created target.
        guard link(temp.path, destination.path) == 0 else { throw DeskError.io("Файл назначения уже существует либо атомарная публикация не поддерживается этим диском. Исходник не изменён.") }
        return copied
    }
}

public struct IntegrityEntry: Codable, Equatable, Sendable {
    public let path: String
    public let digest: FileDigest
}
public struct IntegrityReport: Codable, Sendable {
    public let schema: Int
    public let createdAt: Date
    public let scope: String
    public let originalAuthenticityVerified: Bool
    public let restoreTested: Bool
    public let files: [IntegrityEntry]
    public let warnings: [String]
}
public enum BackupIntegrity {
    public static func baseline(at url: URL, cancellation: CancellationToken? = nil,
                                progress: ((Int) -> Void)? = nil) throws -> IntegrityReport {
        let store = try BackupStore(url: url)
        var paths = Set(["Info.plist", "Manifest.plist", "Status.plist", "Manifest.db"])
        var warnings = ["SHA-256 фиксирует текущее состояние, а не доказывает исходную полноту данных iPhone.",
                        "Проверка восстановления на устройство не выполнена."]
        if !store.metadata.encrypted {
            try store.checkSQLite()
            try store.forEachFile { entry in
                try cancellation?.check()
                paths.insert(try store.payloadPath(entry))
            }
        } else {
            warnings.append("Manifest.db зашифрован: состав и полнота payload не проверены; проверяются только имеющиеся файлы.")
            var enumerationError: Error?
            let root = store.canonicalURL
            let pathPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                                                                  options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw DeskError.io("Не удалось перечислить файлы копии.") }
            for case let item as URL in enumerator {
                try cancellation?.check()
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true else { throw DeskError.invalid("В копии найдена символическая ссылка.") }
                if values.isRegularFile == true {
                    guard item.path.hasPrefix(pathPrefix) else {
                        throw DeskError.invalid("Перечисленный файл находится вне папки резервной копии.")
                    }
                    paths.insert(String(item.path.dropFirst(pathPrefix.count)))
                } else if values.isDirectory != true { throw DeskError.invalid("В копии найден специальный файл.") }
            }
            if let enumerationError { throw enumerationError }
        }
        var entries: [IntegrityEntry] = []
        for path in paths.sorted() {
            try cancellation?.check()
            entries.append(IntegrityEntry(path: path, digest: try Hashing.file(in: store.folder, path: path, cancellation: cancellation)))
            progress?(entries.count)
        }
        return IntegrityReport(schema: 1, createdAt: Date(), scope: store.metadata.encrypted ? "opaque-encrypted-files-only" : "sqlite-and-referenced-payload-presence",
                               originalAuthenticityVerified: false, restoreTested: false, files: entries, warnings: warnings)
    }
    public static func verify(_ report: IntegrityReport, at url: URL, cancellation: CancellationToken? = nil) throws {
        guard report.schema == 1, !report.files.isEmpty else { throw DeskError.invalid("Неподдерживаемый или пустой SHA-256 реестр.") }
        let folder = try SafeFolder(url)
        var seen = Set<String>()
        for entry in report.files {
            try cancellation?.check()
            guard seen.insert(entry.path).inserted,
                  try Hashing.file(in: folder, path: entry.path, cancellation: cancellation) == entry.digest else {
                throw DeskError.invalid("Файл изменён, отсутствует или повторяется в реестре: \(entry.path).")
            }
        }
        let store = try BackupStore(url: url)
        if !store.metadata.encrypted {
            try store.checkSQLite()
            try store.forEachFile { entry in
                guard seen.contains(try store.payloadPath(entry)) else {
                    throw DeskError.invalid("В SHA-256 реестре пропущен файл из Manifest.db.")
                }
            }
        }
        // A baseline must at least cover the metadata; no empty/subset manifest may claim integrity.
        guard Set(["Info.plist", "Manifest.plist", "Status.plist", "Manifest.db"]).isSubset(of: seen) else {
            throw DeskError.invalid("В SHA-256 реестре не хватает обязательных метаданных.")
        }
    }
}
