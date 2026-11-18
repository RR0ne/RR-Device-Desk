#if os(macOS)
import CSQLite
import CryptoKit
import Foundation
import XCTest
@testable import DeviceCore

final class AppDataExporterTests: XCTestCase {
    private let deviceID = "00008101-1234567890123456"
    private let first = InstalledApp(bundleID: "com.example.reader", name: "Reader", version: "1.2", build: "3",
                                     appGroupIDs: ["group.example.reader"])
    private let second = InstalledApp(bundleID: "com.example.notes", name: "Notes", version: "2.0", build: "10")

    func testExistingBackupExportsOnlyExactDomainsAndContinuesAfterMissingApp() throws {
        let fixture = try Fixture()
        try makeSnapshot(fixture, at: fixture.backup)
        let missing = InstalledApp(bundleID: "com.example.empty", name: "Empty", version: "1.0")
        let device = try Device(udid: deviceID, transport: .usb)
        let result = try AppDataExporter().export([missing, first], for: device, from: .existingBackup(fixture.backup),
                                                  to: fixture.base)
        XCTAssertEqual(result.archives.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].contains("Empty"))
        let archive = try XCTUnwrap(result.archives.first)
        let paths = try unzip(["-Z", "-1", archive.path]).output
        XCTAssertTrue(paths.contains("Container/Documents/book.txt\n"))
        XCTAssertTrue(paths.contains("AppGroups/group.example.reader/Library/shared.txt\n"))
        XCTAssertFalse(paths.contains("unrelated.txt"))
        XCTAssertFalse(paths.contains("alias.txt"))
        XCTAssertEqual(try unzip(["-p", archive.path, "Container/Documents/book.txt"]).output, "synthetic")
        let metadata = try manifest(archive)
        XCTAssertEqual(metadata["fileCount"] as? Int, 2)
        XCTAssertEqual(metadata["bundleID"] as? String, first.bundleID)
        XCTAssertNil(metadata["appVersion"])
        let permissions = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path)),
                       ["backup", archive.lastPathComponent])
    }

    func testFreshBatchCapturesOneSnapshotAndCleansItUp() throws {
        let fixture = try Fixture()
        let runner = FakeRunner { [self] request in
            if request.arguments.contains("list") {
                return try plistResult([first, second].map { app in
                    ["CFBundleIdentifier": app.bundleID, "CFBundleDisplayName": app.name,
                     "CFBundleShortVersionString": app.version, "CFBundleVersion": app.build ?? "",
                     "GroupContainers": Dictionary(uniqueKeysWithValues: app.appGroupIDs.map { ($0, "/synthetic") })]
                })
            }
            if request.arguments == ["--version"] {
                return CommandResult(exitCode: 0, stdout: Data("idevicebackup2 1.4.0\n".utf8))
            }
            if request.arguments.contains("validate") { return CommandResult(exitCode: 0) }
            if request.arguments.contains("WillEncrypt") { return try plistResult(false) }
            if request.arguments.contains("--full"), let root = request.arguments.last {
                try makeSnapshot(fixture, at: URL(fileURLWithPath: root).appendingPathComponent(deviceID))
                return CommandResult(exitCode: 0)
            }
            throw DeskError.invalid("Unexpected test command")
        }
        let service = try serviceFixture(fixture, runner: runner)
        let result = try AppDataExporter(service: service).export([first, second],
            for: Device(udid: deviceID, transport: .usb), from: .newTemporaryBackup, to: fixture.base)
        XCTAssertEqual(runner.calls.filter { $0.arguments.contains("--full") }.count, 1)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(try result.archives.map { try manifest($0)["appVersion"] as? String }, ["1.2", "2.0"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path).contains {
            $0.hasPrefix(".rr-appdata-")
        })
    }

    func testWrongDeviceAndEncryptedSourcesDoNotWriteAnArchive() throws {
        let fixture = try Fixture()
        let exporter = AppDataExporter()
        let device = try Device(udid: deviceID, transport: .usb)
        let other = try Device(udid: "00008101-0000000000000000", transport: .usb)
        try fixture.make(encrypted: true)
        XCTAssertThrowsError(try exporter.export([first], for: device, from: .existingBackup(fixture.backup), to: fixture.base))
        XCTAssertThrowsError(try exporter.export([first], for: other, from: .existingBackup(fixture.backup), to: fixture.base))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path), ["backup"])
    }

    private func makeSnapshot(_ fixture: Fixture, at root: URL) throws {
        try fixture.make(at: root)
        let files = [
            ("AppDomain-com.example.reader", "Documents/book.txt"),
            ("AppDomainGroup-group.example.reader", "Library/shared.txt"),
            ("AppDomain-com.example.notes", "Documents/notes.txt"),
            ("AppDomain-com.example.reader.other", "Documents/unrelated.txt"),
            ("AppDomainGroup-group.example.reader.other", "Library/unrelated.txt"),
            ("AppDomain-com.Example.reader", "Documents/alias.txt")
        ]
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("Manifest.db").path, &db) == SQLITE_OK else {
            throw DeskError.io("Could not open fixture manifest")
        }
        defer { sqlite3_close(db) }
        for (domain, path) in files {
            let id = Insecure.SHA1.hash(data: Data((domain + "-" + path).utf8)).map { String(format: "%02x", $0) }.joined()
            let shard = root.appendingPathComponent(String(id.prefix(2)), isDirectory: true)
            try Files.privateDirectory(shard)
            try Data("synthetic".utf8).write(to: shard.appendingPathComponent(id))
            let sql = "INSERT INTO Files VALUES('\(id)','\(domain)','\(path)',1,NULL)"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    private func unzip(_ args: [String]) throws -> CommandResult {
        let result = try ProcessRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: args))
        XCTAssertEqual(result.exitCode, 0)
        return result
    }

    private func manifest(_ archive: URL) throws -> [String: Any] {
        let json = try unzip(["-p", archive.path, "manifest.json"]).stdout
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }
}
#endif
