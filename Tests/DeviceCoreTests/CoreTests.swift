import XCTest
@testable import DeviceCore
import CSQLite
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let udid = "00008101-1234567890123456"
private let fileID = String(repeating: "a", count: 40)

final class Fixture {
    let base: URL
    var backup: URL { base.appendingPathComponent("backup") }
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rrdevice-tests-" + UUID().uuidString)
        try Files.privateDirectory(base)
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    func writePlist(_ value: Any, _ name: String, at root: URL? = nil) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try data.write(to: (root ?? backup).appendingPathComponent(name))
    }
    func make(at root: URL? = nil, encrypted: Bool = false, finished: Bool = true) throws {
        let root = root ?? backup
        try Files.privateDirectory(root)
        try writePlist(["Unique Identifier": udid, "Device Name": "SYNTHETIC TEST FIXTURE - not a real device", "Product Version": "27.0"], "Info.plist", at: root)
        try writePlist(["IsEncrypted": encrypted], "Manifest.plist", at: root)
        try writePlist(["SnapshotState": finished ? "finished" : "new"], "Status.plist", at: root)
        if encrypted {
            // Opaque bytes are not real encrypted Apple data. Tests only verify the rejection boundary.
            try Data("SYNTHETIC OPAQUE FIXTURE".utf8).write(to: root.appendingPathComponent("Manifest.db"))
        } else {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(root.appendingPathComponent("Manifest.db").path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            let sql = "CREATE TABLE Files(fileID TEXT,domain TEXT,relativePath TEXT,flags INTEGER,file BLOB); INSERT INTO Files VALUES('\(fileID)','CameraRollDomain','Media/DCIM/100APPLE/IMG_0001.JPG',1,NULL);"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        try Files.privateDirectory(root.appendingPathComponent("aa"))
        try Data("fixture payload\n".utf8).write(to: root.appendingPathComponent("aa/" + fileID))
    }
    func sql(_ query: String) throws {
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(backup.appendingPathComponent("Manifest.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }; XCTAssertEqual(sqlite3_exec(db, query, nil, nil, nil), SQLITE_OK)
    }
}

final class SafetyTests: XCTestCase {
    func testDecodedDeviceCannotBypassValidation() throws {
        let data = try JSONSerialization.data(withJSONObject: ["udid": "../../escape", "transport": "usb"])
        XCTAssertThrowsError(try JSONDecoder().decode(Device.self, from: data))
        let device = try Device(udid: udid, transport: .usb)
        XCTAssertEqual(try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(device)), device)
    }
    func testNewJSONDoesNotOverwriteOrLeavePartial() throws {
        let f = try Fixture(), url = f.base.appendingPathComponent("report.json")
        try Files.writeNewJSON(["value": 1], to: url)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try Files.writeNewJSON(["value": 2], to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.base.path), ["report.json"])
    }

    func testValidUDIDFormats() throws {
        XCTAssertNoThrow(try Device(udid: udid, transport: .usb))
        XCTAssertNoThrow(try Device(udid: String(repeating: "f", count: 40), transport: .network))
    }
    func testRejectsMalformedUDIDs() {
        for s in ["", "../../x", "--help", "abc;rm -rf /", udid + "\n", "FFFFFFFF-123"] {
            XCTAssertThrowsError(try Device(udid: s, transport: .usb), s)
        }
    }
    func testStrictBooleanPlist() {
        XCTAssertEqual(Plists.bool(true), true)
        XCTAssertEqual(Plists.bool(false), false)
        XCTAssertNil(Plists.bool(1)); XCTAssertNil(Plists.bool("true")); XCTAssertNil(Plists.bool(nil))
    }
    func testUnknownDiskSpaceFailsClosed() { XCTAssertThrowsError(try SafetyPolicy.requiredSpace(usedBytes: nil)) }
    func testInsufficientDiskSpace() { XCTAssertThrowsError(try SafetyPolicy.checkSpace(free: 100, usedBytes: 1000)) }
    func testExactDiskSpaceBoundary() throws {
        let needed = try SafetyPolicy.requiredSpace(usedBytes: 1000)
        XCTAssertNoThrow(try SafetyPolicy.checkSpace(free: needed, usedBytes: 1000))
        XCTAssertThrowsError(try SafetyPolicy.checkSpace(free: needed - 1, usedBytes: 1000))
    }
    func testDiskSpaceOverflow() { XCTAssertThrowsError(try SafetyPolicy.requiredSpace(usedBytes: UInt64.max)) }
    func testRestoreGate() { XCTAssertThrowsError(try SafetyPolicy.permitRestore()) }
    func testPathTraversalRejected() {
        for p in ["../secret", "/tmp/secret", "aa/../../secret", "a//b", "a/./b", "a\\b", "a\0b", ""] {
            XCTAssertThrowsError(try SafeFolder.components(p), p)
        }
    }
    func testSafeRelativePath() throws { XCTAssertEqual(try SafeFolder.components("aa/file"), ["aa", "file"]) }
    func testSymlinkPayloadRejected() throws {
        let f = try Fixture(); try f.make()
        let path = f.backup.appendingPathComponent("aa/" + fileID)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "/etc/passwd")
        XCTAssertThrowsError(try SafeFolder(f.backup).read("aa/" + fileID))
    }
    func testSymlinkParentRejected() throws {
        let f = try Fixture(); try Files.privateDirectory(f.backup)
        try FileManager.default.createSymbolicLink(atPath: f.backup.appendingPathComponent("escape").path, withDestinationPath: "/etc")
        XCTAssertThrowsError(try SafeFolder(f.backup).read("escape/passwd"))
    }
    func testSpecialFileRejectedWithoutBlocking() throws {
        let f = try Fixture(); try Files.privateDirectory(f.backup)
        let fifo = f.backup.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try SafeFolder(f.backup).read("fifo"))
    }
    func testExclusiveCreate() throws {
        let f = try Fixture(), folder = try SafeFolder(f.base)
        let file = try folder.createExclusive("new.txt"); try file.write(contentsOf: Data("old".utf8)); try file.close()
        XCTAssertThrowsError(try folder.createExclusive("new.txt"))
        XCTAssertEqual(try folder.data("new.txt"), Data("old".utf8))
    }
    func testFileLockExcludesSecondWriter() throws {
        let f = try Fixture(); var first: DirectoryLock? = try DirectoryLock(directory: f.base)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try DirectoryLock(directory: f.base))
        first = nil
        XCTAssertNoThrow(try DirectoryLock(directory: f.base))
    }
    func testRedaction() {
        let text = Redactor.text("device \(udid)\nPassword: hunter2\nhello TOKEN=abcd", secrets: ["hunter2"])
        XCTAssertFalse(text.contains(udid)); XCTAssertFalse(text.contains("hunter2")); XCTAssertFalse(text.contains("abcd"))
    }
    func testSHA256KnownVector() throws {
        let f = try Fixture(), folder = try SafeFolder(f.base)
        try Data("abc".utf8).write(to: f.base.appendingPathComponent("abc"))
        let hash = try Hashing.file(in: folder, path: "abc")
        XCTAssertEqual(hash.bytes, 3)
        XCTAssertEqual(hash.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testSHA256EmptyVector() throws {
        let f = try Fixture(); try Data().write(to: f.base.appendingPathComponent("empty"))
        XCTAssertEqual(try Hashing.file(in: SafeFolder(f.base), path: "empty").sha256,
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}

final class BackupTests: XCTestCase {
    func testEmbeddedNULPathIsRejected() throws {
        let f = try Fixture(); try f.make()
        try f.sql("UPDATE Files SET relativePath='safe' || char(0) || '../escape';")
        XCTAssertThrowsError(try BackupStore(url: f.backup).entries())
    }
    func testMissingPayloadFromBaselineIsRejected() throws {
        let f = try Fixture(); try f.make()
        let report = try BackupIntegrity.baseline(at: f.backup)
        let incomplete = IntegrityReport(schema: 1, createdAt: report.createdAt, scope: report.scope,
            originalAuthenticityVerified: false, restoreTested: false,
            files: report.files.filter { !$0.path.hasPrefix("aa/") }, warnings: report.warnings)
        XCTAssertThrowsError(try BackupIntegrity.verify(incomplete, at: f.backup))
    }
    func testBaselineRejectsDuplicateFileIDs() throws {
        let f = try Fixture(); try f.make()
        try f.sql("INSERT INTO Files SELECT * FROM Files;")
        XCTAssertThrowsError(try BackupIntegrity.baseline(at: f.backup))
    }

    func testMetadataAndListing() throws {
        let f = try Fixture(); try f.make(); let store = try BackupStore(url: f.backup)
        XCTAssertEqual(store.metadata.udid, udid); XCTAssertFalse(store.metadata.encrypted)
        XCTAssertEqual(try store.entries().count, 1)
        XCTAssertEqual(try store.entries(search: "DCIM").first?.fileID, fileID)
    }
    func testSearchDoesNotInterpretSQL() throws {
        let f = try Fixture(); try f.make(); let store = try BackupStore(url: f.backup)
        XCTAssertTrue(try store.entries(search: "' OR 1=1 --").isEmpty)
        XCTAssertTrue(try store.entries(search: "%").isEmpty)
        XCTAssertEqual(try store.entries().count, 1)
    }
    func testFinishedStateRequired() throws {
        let f = try Fixture(); try f.make(finished: false)
        XCTAssertThrowsError(try BackupStore(url: f.backup))
    }
    func testMissingEncryptionStateRejected() throws {
        let f = try Fixture(); try f.make(); try f.writePlist(["Other": true], "Manifest.plist")
        XCTAssertThrowsError(try BackupStore(url: f.backup))
    }
    func testCorruptDatabaseRejected() throws {
        let f = try Fixture(); try f.make(); try Data("not sqlite".utf8).write(to: f.backup.appendingPathComponent("Manifest.db"))
        XCTAssertThrowsError(try BackupStore(url: f.backup))
    }
    func testUnknownSchemaRejected() throws {
        let f = try Fixture(); try f.make(); try f.sql("DROP TABLE Files; CREATE TABLE SomethingElse(x);")
        XCTAssertThrowsError(try BackupStore(url: f.backup))
    }
    func testActiveWALRejected() throws {
        let f = try Fixture(); try f.make(); try Data("not checkpointed".utf8).write(to: f.backup.appendingPathComponent("Manifest.db-wal"))
        XCTAssertThrowsError(try BackupStore(url: f.backup))
    }
    func testDatabaseNotModifiedByReads() throws {
        let f = try Fixture(); try f.make(); let folder = try SafeFolder(f.backup)
        let before = try Hashing.file(in: folder, path: "Manifest.db")
        let store = try BackupStore(url: f.backup); _ = try store.entries(); try store.checkSQLite()
        XCTAssertEqual(try Hashing.file(in: folder, path: "Manifest.db"), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.appendingPathComponent("Manifest.db-wal").path))
    }
    func testTraversalInManifestRejected() throws {
        let f = try Fixture(); try f.make(); try f.sql("UPDATE Files SET relativePath='../etc/passwd';")
        XCTAssertThrowsError(try BackupStore(url: f.backup).entries())
    }
    func testDuplicateFileIDRejectedForExport() throws {
        let f = try Fixture(); try f.make(); try f.sql("INSERT INTO Files SELECT * FROM Files;")
        XCTAssertThrowsError(try BackupStore(url: f.backup).file(id: fileID))
    }
    func testExportIsByteExact() throws {
        let f = try Fixture(); try f.make(); let dest = f.base.appendingPathComponent("export.jpg")
        let result = try BackupStore(url: f.backup).export(id: fileID, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), Data("fixture payload\n".utf8)); XCTAssertEqual(result.bytes, 16)
    }
    func testExportNeverOverwrites() throws {
        let f = try Fixture(); try f.make(); let dest = f.base.appendingPathComponent("export.jpg")
        try Data("preserve".utf8).write(to: dest)
        XCTAssertThrowsError(try BackupStore(url: f.backup).export(id: fileID, to: dest))
        XCTAssertEqual(try Data(contentsOf: dest), Data("preserve".utf8))
    }
    func testExportIntoSourceRejected() throws {
        let f = try Fixture(); try f.make()
        XCTAssertThrowsError(try BackupStore(url: f.backup).export(id: fileID, to: f.backup.appendingPathComponent("export.jpg")))
    }
    func testExportSymlinkTargetNeverFollowed() throws {
        let f = try Fixture(); try f.make()
        let target = f.base.appendingPathComponent("target"), export = f.base.appendingPathComponent("export")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: export.path, withDestinationPath: target.path)
        XCTAssertThrowsError(try BackupStore(url: f.backup).export(id: fileID, to: export))
        XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))
    }
    func testBaselineAndVerification() throws {
        let f = try Fixture(); try f.make(); let report = try BackupIntegrity.baseline(at: f.backup)
        XCTAssertEqual(report.files.count, 5)
        XCTAssertFalse(report.originalAuthenticityVerified); XCTAssertFalse(report.restoreTested)
        XCTAssertNoThrow(try BackupIntegrity.verify(report, at: f.backup))
    }
    func testBaselineDetectsTampering() throws {
        let f = try Fixture(); try f.make(); let report = try BackupIntegrity.baseline(at: f.backup)
        try Data("changed".utf8).write(to: f.backup.appendingPathComponent("aa/" + fileID))
        XCTAssertThrowsError(try BackupIntegrity.verify(report, at: f.backup))
    }
    func testMissingPayloadFailsValidation() throws {
        let f = try Fixture(); try f.make(); try FileManager.default.removeItem(at: f.backup.appendingPathComponent("aa/" + fileID))
        XCTAssertThrowsError(try BackupIntegrity.baseline(at: f.backup))
    }
    func testEncryptedCopyNotPretendedReadable() throws {
        let f = try Fixture(); try f.make(encrypted: true); let store = try BackupStore(url: f.backup)
        XCTAssertTrue(store.metadata.encrypted); XCTAssertThrowsError(try store.entries())
        let report = try BackupIntegrity.baseline(at: f.backup)
        XCTAssertEqual(report.scope, "opaque-encrypted-files-only"); XCTAssertFalse(report.restoreTested)
    }
    func testHashCancellation() throws {
        let f = try Fixture(); try f.make(); let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try BackupIntegrity.baseline(at: f.backup, cancellation: token))
    }
}

final class ProcessTests: XCTestCase {
    func testLongProgressOutputUsesBoundedTailWithoutFailing() throws {
        let result = try ProcessRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "2000000", "/dev/zero"], outputPolicy: .tail))
        XCTAssertEqual(result.exitCode, 0); XCTAssertTrue(result.outputTruncated)
        XCTAssertEqual(result.stdout.count, 256 * 1024)
    }
    func testOversizedExactOutputFailsClosed() throws {
        XCTAssertThrowsError(try ProcessRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "18000000", "/dev/zero"])))
    }

    func testActualProcessNoShellInjection() throws {
        let r = try ProcessRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello; $(echo injected)"]))
        XCTAssertEqual(r.exitCode, 0); XCTAssertEqual(r.output, "hello; $(echo injected)\n")
    }
    func testActualNonzeroExitPreserved() throws {
        let r = try ProcessRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: []))
        XCTAssertNotEqual(r.exitCode, 0)
    }
    func testActualProcessTimeout() {
        XCTAssertThrowsError(try ProcessRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1))) { error in
            XCTAssertEqual(error as? DeskError, .timeout)
        }
    }
    func testActualProcessCancellation() {
        let token = CancellationToken(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        XCTAssertThrowsError(try ProcessRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]), cancellation: token)) { error in
            XCTAssertEqual(error as? DeskError, .cancelled)
        }
    }
    func testAlreadyCancelledProcessNotStarted() {
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try ProcessRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/nonexistent"), arguments: []), cancellation: token)) { error in
            XCTAssertEqual(error as? DeskError, .cancelled)
        }
    }
    func testEnvironmentIsAllowlisted() throws {
        let r = try ProcessRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: []))
        let keys = Set(r.output.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        XCTAssertEqual(keys, Set(["HOME", "PATH", "LANG", "LC_ALL"]))
    }
    func testRejectsEnvironmentInjection() {
        XCTAssertThrowsError(try ProcessRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], secretEnvironment: ["DYLD_INSERT_LIBRARIES": "bad"])))
    }
    func testConcurrentStdoutAndStderrDoNotDeadlock() throws {
        let f = try Fixture(), script = f.base.appendingPathComponent("both-streams.sh")
        try Data("#!/bin/sh\ni=0; while [ $i -lt 20000 ]; do printf 'abcdefghij\\n'; printf 'klmnopqrst\\n' >&2; i=$((i+1)); done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let r = try ProcessRunner().run(CommandRequest(executable: script, arguments: [], timeout: 20))
        XCTAssertEqual(r.exitCode, 0); XCTAssertEqual(r.stdout.count, 220000); XCTAssertEqual(r.stderr.count, 220000)
    }
}

final class FakeRunner: CommandRunning {
    var calls: [CommandRequest] = []
    var respond: (CommandRequest) throws -> CommandResult
    init(_ respond: @escaping (CommandRequest) throws -> CommandResult) { self.respond = respond }
    func run(_ request: CommandRequest, cancellation: CancellationToken?, guardCheck: (() throws -> Void)?) throws -> CommandResult {
        try cancellation?.check(); try guardCheck?(); calls.append(request); return try respond(request)
    }
}
func plistResult(_ object: Any) throws -> CommandResult {
    CommandResult(exitCode: 0, stdout: try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0))
}
func serviceFixture(_ f: Fixture, runner: FakeRunner) throws -> DeviceService {
    let tools = f.base.appendingPathComponent("test-tools"); try Files.privateDirectory(tools)
    for tool in Tool.allCases {
        let path = tools.appendingPathComponent(tool.rawValue)
        if !FileManager.default.fileExists(atPath: path.path) {
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
    }
    return DeviceService(runner: runner, tools: Toolchain(directories: [tools]))
}
final class DeviceServiceTests: XCTestCase {
    func testUSBAndNetworkArguments() throws {
        let f = try Fixture(), runner = FakeRunner { _ in CommandResult(exitCode: 0, stdout: Data((udid + "\n").utf8)) }
        let s = try serviceFixture(f, runner: runner)
        XCTAssertEqual(try s.devices(transport: .usb).count, 1)
        XCTAssertEqual(try s.devices(transport: .network).first?.transport, .network)
        XCTAssertEqual(runner.calls[0].arguments, ["--list"]); XCTAssertEqual(runner.calls[1].arguments, ["--network"])
    }
    func testNoDeviceIsAnEmptyListNotFakeDevice() throws {
        let f = try Fixture(), runner = FakeRunner { _ in CommandResult(exitCode: 0) }
        XCTAssertTrue(try serviceFixture(f, runner: runner).devices(transport: .usb).isEmpty)
    }
    func testPairRequiresConfirmation() throws {
        let f = try Fixture(), runner = FakeRunner { _ in XCTFail("Must not execute"); return CommandResult(exitCode: 0) }
        XCTAssertThrowsError(try serviceFixture(f, runner: runner).pair(Device(udid: udid, transport: .usb), confirmed: false))
        XCTAssertTrue(runner.calls.isEmpty)
    }
    func testFailedPairValidationIsNotSuccess() throws {
        let f = try Fixture(), runner = FakeRunner { q in CommandResult(exitCode: q.arguments.contains("validate") ? 1 : 0) }
        XCTAssertThrowsError(try serviceFixture(f, runner: runner).pair(Device(udid: udid, transport: .usb), confirmed: true))
    }
    func testPasswordNotInArgumentsAndStateVerified() throws {
        let f = try Fixture(); var enabled = false
        let runner = FakeRunner { q in
            if q.arguments == ["--version"] { return CommandResult(exitCode: 0, stdout: Data("idevicebackup2 1.4.0\n".utf8)) }
            if q.arguments.contains("encryption") { enabled = true; XCTAssertEqual(q.secretEnvironment["BACKUP_PASSWORD"], "synthetic-secret"); return CommandResult(exitCode: 0) }
            return try plistResult(enabled)
        }
        try serviceFixture(f, runner: runner).enableEncryption(Device(udid: udid, transport: .usb), password: "synthetic-secret", confirmed: true)
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("synthetic-secret") })
        XCTAssertTrue(enabled)
    }
    func testUnknownBackendVersionBlocked() throws {
        let f = try Fixture(), runner = FakeRunner { _ in CommandResult(exitCode: 0, stdout: Data("idevicebackup2 9.9.9\n".utf8)) }
        XCTAssertThrowsError(try serviceFixture(f, runner: runner).requireBackupVersion())
    }
    func testMissingToolsAreErrors() throws {
        let f = try Fixture(), s = DeviceService(tools: Toolchain(directories: [f.base]))
        XCTAssertThrowsError(try s.devices(transport: .usb))
        XCTAssertTrue(s.doctor().allSatisfy { $0.error != nil })
    }
    func testBackupSuccessRequiresRealFilesNotOnlyExitZero() throws {
        try checkEngine(mode: "no-output", success: false)
    }
    func testBackupNonzeroRetainsPartial() throws { try checkEngine(mode: "nonzero", success: false) }
    func testBackupFixtureIntegrationPromotesAfterVerification() throws { try checkEngine(mode: "complete-fixture", success: true) }
    private func checkEngine(mode: String, success: Bool) throws {
        let f = try Fixture(); let root = f.base.appendingPathComponent("jobs")
        let runner = FakeRunner { q in
            if q.arguments == ["--version"] { return CommandResult(exitCode: 0, stdout: Data("idevicebackup2 1.4.0\n".utf8)) }
            if q.arguments.contains("validate") { return CommandResult(exitCode: 0) }
            if q.arguments.contains("WillEncrypt") { return try plistResult(false) }
            if q.arguments.contains("com.apple.disk_usage") { return try plistResult(["TotalDataCapacity": 1000, "TotalDataAvailable": 500]) }
            if q.arguments.contains("--xml") { return try plistResult(["ProductVersion": "27.0", "DeviceName": "SYNTHETIC", "ProductType": "Test", "BuildVersion": "TEST"]) }
            if q.arguments.contains("backup") {
                if mode == "complete-fixture" { try f.make(at: URL(fileURLWithPath: q.arguments.last!).appendingPathComponent(udid)) }
                return CommandResult(exitCode: mode == "nonzero" ? 1 : 0)
            }
            throw DeskError.invalid("Unexpected mocked command")
        }
        let engine = BackupEngine(service: try serviceFixture(f, runner: runner))
        let operation = { try engine.create(device: Device(udid: udid, transport: .usb), root: root, allowUnencrypted: true, confirmed: true) }
        if success {
            let result = try operation(); XCTAssertEqual(result.job.state, "completed-structure-checked")
            XCTAssertTrue(result.directory.lastPathComponent.hasPrefix("Backup-"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("integrity.json").path))
        } else { XCTAssertThrowsError(try operation()) }
        let history = try BackupEngine.history(root: root)
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0].state, success ? "completed-structure-checked" : "failed")
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(folders.filter { $0.hasPrefix("Backup-") }.count, success ? 1 : 0)
        XCTAssertEqual(folders.filter { $0.hasPrefix(".partial-") }.count, success ? 0 : 1)
    }
}
