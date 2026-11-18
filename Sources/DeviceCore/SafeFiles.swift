import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import COpenSSL
#endif

/// Files from a backup are untrusted. Open each component relative to a directory FD.
/// No symlinks, '..', absolute paths or special files are accepted.
public final class SafeFolder {
    public let url: URL
    private let fd: Int32
    public init(_ url: URL) throws {
        self.url = url.standardizedFileURL
        fd = open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DeskError.io("Не удалось безопасно открыть папку: \(self.url.lastPathComponent).") }
    }
    deinit { _ = close(fd) }
    public static func components(_ relative: String) throws -> [String] {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"), !relative.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DeskError.invalid("Небезопасный относительный путь.")
        }
        return parts
    }
    private func parent(_ parts: [String]) throws -> Int32 {
        var current = dup(fd)
        guard current >= 0 else { throw DeskError.io("Не удалось открыть файловый дескриптор.") }
        for part in parts.dropLast() {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            _ = close(current)
            guard next >= 0 else { throw DeskError.io("Папка отсутствует или является ссылкой.") }
            current = next
        }
        return current
    }
    public func read(_ relative: String) throws -> FileHandle {
        let parts = try Self.components(relative), dir = try parent(parts)
        defer { _ = close(dir) }
        let file = openat(dir, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw DeskError.io("Файл отсутствует или недоступен: \(relative).") }
        var st = stat()
        guard fstat(file, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            _ = close(file); throw DeskError.invalid("Разрешено чтение только обычных файлов.")
        }
        return FileHandle(fileDescriptor: file, closeOnDealloc: true)
    }
    public func createExclusive(_ relative: String) throws -> FileHandle {
        let parts = try Self.components(relative), dir = try parent(parts)
        defer { _ = close(dir) }
        let file = openat(dir, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw DeskError.io("Файл уже существует или запись невозможна: \(relative). Перезапись запрещена.") }
        return FileHandle(fileDescriptor: file, closeOnDealloc: true)
    }
    public func data(_ relative: String, maxBytes: Int = 32 * 1024 * 1024) throws -> Data {
        let handle = try read(relative); defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw DeskError.invalid("Файл превышает безопасный лимит разбора.") }
        return data
    }
}

public final class DirectoryLock {
    private let fd: Int32
    public init(directory: URL, name: String = ".rrdevice.lock") throws {
        _ = try SafeFolder.components(name)
        guard !name.contains("/") else { throw DeskError.invalid("Недопустимое имя блокировки.") }
        fd = open(directory.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw DeskError.io("Невозможно создать блокировку.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { _ = close(fd); throw DeskError.busy }
    }
    deinit { _ = flock(fd, LOCK_UN); _ = close(fd) }
}

public enum Files {
    public static func privateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        _ = try SafeFolder(url)
    }
    public static func freeBytes(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let n = attrs[.systemFreeSize] as? NSNumber else { throw DeskError.io("Не удалось определить свободное место.") }
        return n.uint64Value
    }
    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        // Temp file has mode 0600 before any bytes are written. Rename is atomic.
        let folder = try SafeFolder(url.deletingLastPathComponent())
        let name = ".\(UUID().uuidString).tmp"
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(name)
        let handle = try folder.createExclusive(name)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: tempURL) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard rename(tempURL.path, url.path) == 0 else { throw DeskError.io("Не удалось атомарно сохранить JSON.") }
    }
    /// Publish a NEW report only after all bytes are synced. Never replace a user file.
    public static func writeNewJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let folder = try SafeFolder(url.deletingLastPathComponent())
        _ = try SafeFolder.components(url.lastPathComponent)
        let name = ".rr-report-\(UUID().uuidString).partial"
        let temp = url.deletingLastPathComponent().appendingPathComponent(name)
        let handle = try folder.createExclusive(name)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard link(temp.path, url.path) == 0 else {
            throw DeskError.io("Отчёт уже существует или диск не поддерживает атомарную публикацию. Перезапись не выполнена.")
        }
    }
    public static func readJSON<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let data = try SafeFolder(url.deletingLastPathComponent()).data(url.lastPathComponent)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
    public static func isInside(_ candidate: URL, root: URL) -> Bool {
        let r = root.resolvingSymlinksInPath().standardizedFileURL.path
        let c = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return c == r || c.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}

public struct FileDigest: Codable, Equatable, Sendable {
    public let bytes: UInt64
    public let sha256: String
}
public enum Hashing {
    public static func digest(_ handle: FileHandle, cancellation: CancellationToken? = nil) throws -> FileDigest {
        var size: UInt64 = 0
        #if canImport(CryptoKit)
        var hash = SHA256()
        #else
        guard let context = EVP_MD_CTX_new() else { throw DeskError.io("Не удалось создать SHA-256 контекст.") }
        defer { EVP_MD_CTX_free(context) }
        guard EVP_DigestInit_ex(context, EVP_sha256(), nil) == 1 else { throw DeskError.io("Ошибка SHA-256.") }
        #endif
        while true {
            try cancellation?.check()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            size += UInt64(data.count)
            #if canImport(CryptoKit)
            hash.update(data: data)
            #else
            let ok = data.withUnsafeBytes { EVP_DigestUpdate(context, $0.baseAddress, $0.count) }
            guard ok == 1 else { throw DeskError.io("Ошибка SHA-256.") }
            #endif
        }
        #if canImport(CryptoKit)
        let bytes = Array(hash.finalize())
        #else
        var bytes = [UInt8](repeating: 0, count: 32); var count: UInt32 = 0
        guard EVP_DigestFinal_ex(context, &bytes, &count) == 1, count == 32 else { throw DeskError.io("Ошибка SHA-256.") }
        #endif
        return FileDigest(bytes: size, sha256: bytes.map { String(format: "%02x", $0) }.joined())
    }
    public static func file(in folder: SafeFolder, path: String, cancellation: CancellationToken? = nil) throws -> FileDigest {
        let h = try folder.read(path); defer { try? h.close() }
        return try digest(h, cancellation: cancellation)
    }
}
