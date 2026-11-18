import Foundation
@testable import DeviceCore
import XCTest

final class AppLibraryTests: XCTestCase {
    private let bundleID = "com.example.rrfixture"

    private func fixture(storeAccount: String? = nil, artwork: String = "fixture",
                         packageBundleID: String? = nil) throws -> (Fixture, AppLibrary, URL) {
        let f = try Fixture()
        let bundleID = packageBundleID ?? self.bundleID
        let app = f.base.appendingPathComponent("Payload/Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "Example Test",
            "CFBundleShortVersionString": "2.1", "CFBundleVersion": "13", "CFBundleExecutable": "Demo"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try Data("SYNTHETIC; not an installable binary.".utf8).write(to: app.appendingPathComponent("Demo"))
        let package = f.base.appendingPathComponent("fixture.ipa")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = f.base
        var archiveEntries = ["Payload"]
        if let storeAccount {
            let metadata: [String: Any] = ["itemId": 42, "softwareVersionExternalIdentifier": 100,
                                          "softwareVersionBundleId": bundleID, "userName": storeAccount]
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
                .write(to: f.base.appendingPathComponent("iTunesMetadata.plist"))
            try Data(artwork.utf8).write(to: f.base.appendingPathComponent("iTunesArtwork"))
            archiveEntries += ["iTunesMetadata.plist", "iTunesArtwork"]
        }
        process.arguments = ["-qr", package.path] + archiveEntries
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DeskError.io("Fixture zip failed.") }
        return (f, AppLibrary(root: f.base.appendingPathComponent("library")), package)
    }

    func testImportsOnceAndRetainsIndependentOriginalBytes() throws {
        let (f, library, package) = try fixture()
        defer { withExtendedLifetime(f) {} }
        let bytes = try Data(contentsOf: package)
        let first = try library.importPackage(package)
        XCTAssertEqual(first.bundleID, bundleID)
        XCTAssertEqual(first.name, "Example Test")
        XCTAssertEqual(first.version, "2.1")
        XCTAssertEqual(try library.importPackage(package).id, first.id)
        try FileManager.default.removeItem(at: package)
        let reopened = AppLibrary(root: library.root)
        XCTAssertEqual(try reopened.entries().map(\.id), [first.id])
        XCTAssertEqual(try Data(contentsOf: reopened.verifiedPackage(first)), bytes)
    }

    func testWrongBundleAndModifiedPayloadAreRejected() throws {
        let (f, library, package) = try fixture()
        defer { withExtendedLifetime(f) {} }
        XCTAssertThrowsError(try library.importPackage(package, expectedBundleID: "com.example.different"))
        XCTAssertTrue(try library.entries().isEmpty)
        let saved = try library.importPackage(package)
        try Data("damaged".utf8).write(to: library.verifiedPackage(saved))
        XCTAssertThrowsError(try library.verifiedPackage(saved))
    }

    func testCopyUsesExactLocalVersionWithoutNetwork() throws {
        let (f, library, package) = try fixture()
        defer { withExtendedLifetime(f) {} }
        let saved = try library.importPackage(package)
        let app = InstalledApp(bundleID: bundleID, name: saved.name, version: saved.version, build: saved.build)
        XCTAssertEqual(try library.copyApp(app, tool: nil).id, saved.id)
        let otherBuild = InstalledApp(bundleID: bundleID, name: saved.name, version: saved.version, build: "12")
        XCTAssertThrowsError(try library.copyApp(otherBuild, tool: nil))
    }

    func testBatchCopyContinuesAfterFailureAndPreservesCompletedWorkOnCancel() throws {
        let (fixture, library, archive) = try self.fixture()
        defer { withExtendedLifetime(fixture) {} }
        let saved = try library.importPackage(archive)
        let good = InstalledApp(bundleID: bundleID, name: saved.name, version: saved.version, build: saved.build)
        let missing = InstalledApp(bundleID: "com.example.missing", name: "Missing", version: "1.0")
        let device = try Device(udid: "00008101-1234567890123456", transport: .usb)
        var requested: [String] = []
        let runner = FakeRunner { request in
            let index = try XCTUnwrap(request.arguments.firstIndex(of: "--bundle-identifier"))
            let id = request.arguments[index + 1]
            requested.append(id)
            let apps = id == self.bundleID ? [["CFBundleIdentifier": id, "CFBundleShortVersionString": "2.1",
                                                 "CFBundleVersion": "13"]] : []
            return try plistResult(apps)
        }
        let service = try serviceFixture(fixture, runner: runner)
        let partial = library.copyApps([missing, good], from: device, service: service, tool: nil,
                                         cancellation: CancellationToken()) { _, _ in }
        XCTAssertEqual(partial.completed.map(\.id), [saved.id])
        XCTAssertEqual(partial.failures.count, 1)
        XCTAssertTrue(partial.failures.first?.contains("Missing") == true)
        XCTAssertEqual(requested, [missing.id, good.id])

        requested.removeAll()
        let token = CancellationToken()
        let stopped = library.copyApps([good, missing], from: device, service: service, tool: nil, cancellation: token) { index, _ in
            if index == 2 { token.cancel() }
        }
        XCTAssertEqual(stopped.completed.map(\.id), [saved.id])
        XCTAssertTrue(stopped.failures.isEmpty)
        XCTAssertEqual(requested, [good.id])
        XCTAssertEqual(try library.entries().map(\.id), [saved.id])
    }

    func testDeviceListKeepsSingleComponentBundleIdentifiers() throws {
        let f = try Fixture()
        let attributes = ["CFBundleIdentifier": "StandaloneApp", "CFBundleDisplayName": "Standalone",
                          "CFBundleShortVersionString": "1.0"]
        let runner = FakeRunner { _ in try plistResult([attributes]) }
        let service = try serviceFixture(f, runner: runner)
        let device = try Device(udid: "00008101-1234567890123456", transport: .usb)
        XCTAssertEqual(try service.installedApps(device).map(\.bundleID), ["StandaloneApp"])
        XCTAssertThrowsError(try service.installedApps(device, bundleID: "--all"))
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testCopyReadsTheSelectedAppsCatalogIdentifiersAndSkipsStaleVersionMetadata() throws {
        let f = try Fixture()
        let device = try Device(udid: "00008101-1234567890123456", transport: .usb)
        let selection = InstalledApp(bundleID: bundleID, name: "Example Test", version: "2.1", build: "13")
        var metadataBuild = "13"
        let runner = FakeRunner { request in
            XCTAssertTrue(request.arguments.contains("CFBundleVersion"))
            XCTAssertTrue(request.arguments.contains("iTunesMetadata"))
            XCTAssertTrue(request.arguments.contains(self.bundleID))
            let metadata = try PropertyListSerialization.data(fromPropertyList: [
                "itemId": 42, "softwareVersionExternalIdentifier": 100,
                "softwareVersionBundleId": self.bundleID, "bundleVersion": metadataBuild,
                "enterpriseInstallURL": "itms-services://?action=download-manifest&url=https%3A%2F%2Fcdn.example.com%2Fmanifest.plist"
            ], format: .binary, options: 0)
            return try plistResult([["CFBundleIdentifier": self.bundleID,
                                     "CFBundleShortVersionString": "2.1", "CFBundleVersion": "13",
                                     "iTunesMetadata": metadata]])
        }
        let service = try serviceFixture(f, runner: runner)
        let exact = try service.installedAppForCopy(selection, on: device)
        XCTAssertEqual(exact.storeID, 42)
        XCTAssertEqual(exact.externalVersionID, 100)
        XCTAssertEqual(exact.installManifestURL?.absoluteString, "https://cdn.example.com/manifest.plist")
        metadataBuild = "12"
        XCTAssertNil(try service.installedAppForCopy(selection, on: device).externalVersionID)
    }

    func testInstallerDownloadsTheSelectedIPAVersionFromItsManifestOrigin() throws {
        let (f, library, archive) = try fixture()
        defer { withExtendedLifetime(f) {} }
        let manifest = try XCTUnwrap(URL(string: "https://cdn.example.com/manifest.plist"))
        var packageAddress = "https://other.example.com/app.ipa"
        var fetchedPackage = false
        let runner = FakeRunner { request in
            guard request.executable.path == "/usr/bin/curl" else { return try ProcessRunner().run(request) }
            let output = try XCTUnwrap(request.arguments.firstIndex(of: "--output"))
            let destination = URL(fileURLWithPath: request.arguments[output + 1])
            if request.arguments.last == manifest.absoluteString {
                let plist = try PropertyListSerialization.data(fromPropertyList: ["items": [[
                    "metadata": ["bundle-identifier": self.bundleID, "bundle-version": "37"],
                    "assets": [["kind": "software-package", "url": packageAddress]]
                ]]], format: .xml, options: 0)
                try plist.write(to: destination)
            } else {
                fetchedPackage = true
                try FileManager.default.copyItem(at: archive, to: destination)
            }
            return CommandResult(exitCode: 0, stdout: Data("200".utf8))
        }
        let target = AppLibrary(root: library.root, runner: runner)
        let exact = InstalledApp(bundleID: bundleID, name: "Fixture", version: "2.1", build: "13", installManifestURL: manifest)
        XCTAssertThrowsError(try target.copyApp(exact, tool: nil))
        XCTAssertFalse(fetchedPackage)
        packageAddress = "https://cdn.example.com/app.ipa"
        let wrongBuild = InstalledApp(bundleID: bundleID, name: "Fixture", version: "2.1", build: "14", installManifestURL: manifest)
        XCTAssertThrowsError(try target.copyApp(wrongBuild, tool: nil))
        XCTAssertTrue(fetchedPackage)
        XCTAssertTrue(try target.entries().isEmpty)
        let saved = try target.copyApp(exact, tool: nil)
        XCTAssertEqual(saved.build, "13")
        XCTAssertEqual(try target.entries().map(\.id), [saved.id])
    }

    func testDownloadedIPAMustMatchRequestedAppVersionAndBuildBeforeSaving() throws {
        let (f, library, package) = try fixture()
        defer { withExtendedLifetime(f) {} }
        let downloader = URL(fileURLWithPath: "/test/ipatool")
        let runner = FakeRunner { request in
            if request.executable == downloader {
                XCTAssertTrue(request.arguments.contains("--non-interactive"))
                XCTAssertFalse(request.arguments.contains("--purchase"))
                XCTAssertFalse(request.arguments.contains("--bundle-identifier"))
                let store = try XCTUnwrap(request.arguments.firstIndex(of: "--app-id"))
                let version = try XCTUnwrap(request.arguments.firstIndex(of: "--external-version-id"))
                XCTAssertEqual(request.arguments[store + 1], "42")
                XCTAssertEqual(request.arguments[version + 1], "100")
                let target = try XCTUnwrap(request.arguments.last)
                try FileManager.default.copyItem(at: package, to: URL(fileURLWithPath: target))
                return CommandResult(exitCode: 0)
            }
            return try ProcessRunner().run(request)
        }
        let target = AppLibrary(root: library.root, runner: runner)
        for (id, version, build) in [("com.example.other", "2.1", "13"), (bundleID, "2.0", "13"), (bundleID, "2.1", "12")] {
            let wrong = InstalledApp(bundleID: id, name: "Example Test", version: version, build: build,
                                     storeID: 42, externalVersionID: 100)
            XCTAssertThrowsError(try target.copyApp(wrong, tool: downloader))
            XCTAssertTrue(try target.entries().isEmpty)
        }
        let selected = InstalledApp(bundleID: bundleID, name: "Example Test", version: "2.1", build: "13",
                                    storeID: 42, externalVersionID: 100)
        let saved = try target.copyApp(selected, tool: downloader)
        XCTAssertEqual(try target.entries().map(\.bundleID), [bundleID])
        XCTAssertEqual(try Data(contentsOf: target.verifiedPackage(saved)), try Data(contentsOf: package))
        XCTAssertTrue(target.root.path.hasPrefix(f.base.path))
    }

    func testStoreSearchAndDownloadUseSelectedIDAndVerifyBundle() throws {
        let (f, library, package) = try fixture()
        defer { withExtendedLifetime(f) {} }
        let tool = URL(fileURLWithPath: "/test/ipatool")
        let runner = FakeRunner { request in
            guard request.executable == tool else { return try ProcessRunner().run(request) }
            if request.arguments.contains("search") {
                XCTAssertEqual(Array(request.arguments.suffix(2)), ["--", "Тест"])
                let result = #"{"apps":[{"id":42,"bundleID":"com.example.rrfixture","name":"Тест","version":"2.1"}]}"#
                return CommandResult(exitCode: 0, stderr: Data(result.utf8))
            }
            XCTAssertTrue(request.arguments.contains("--non-interactive"))
            XCTAssertFalse(request.arguments.contains("--purchase"))
            XCTAssertFalse(request.arguments.contains("--bundle-identifier"))
            let idFlag = try XCTUnwrap(request.arguments.firstIndex(of: "--app-id"))
            XCTAssertEqual(request.arguments[idFlag + 1], "42")
            let output = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            try FileManager.default.copyItem(at: package, to: output)
            return CommandResult(exitCode: 0)
        }
        let target = AppLibrary(root: library.root, runner: runner)
        let app = try XCTUnwrap(target.searchStore(" Тест ", tool: tool).first)
        XCTAssertEqual(try target.downloadStoreApp(app, tool: tool).bundleID, bundleID)
        let wrong = StoreApp(id: app.id, bundleID: "com.example.other", name: app.name, version: app.version)
        XCTAssertThrowsError(try target.downloadStoreApp(wrong, tool: tool))
        XCTAssertEqual(try target.entries().map(\.bundleID), [bundleID])
    }

    func testPurchaseListOpensAllRowsAndRejectsAnIncompleteResponse() throws {
        let tool = URL(fileURLWithPath: "/test/ipatool")
        let rows: [[String: Any]] = (1...107).map { id in
            ["id": id, "bundleID": "com.example.app\(id)", "name": "App \(id)", "version": "1"]
        }
        var totalCount = rows.count
        let runner = FakeRunner { request in
            XCTAssertEqual(request.executable, tool)
            XCTAssertEqual(request.arguments, ["--format", "json", "--non-interactive", "list-purchases", "--platform", "iphone", "--all"])
            let output = try JSONSerialization.data(withJSONObject: ["apps": rows, "totalCount": totalCount])
            return CommandResult(exitCode: 0, stderr: output)
        }
        let library = AppLibrary(root: URL(fileURLWithPath: "/test/library"), runner: runner)
        XCTAssertEqual(try library.purchasedApps(tool: tool).last?.id, 107)
        totalCount += 1
        XCTAssertThrowsError(try library.purchasedApps(tool: tool))
    }

    func testStoreDownloadsReuseTheSameLicensedBuildAcrossDifferentZIPBytes() throws {
        let (first, library, original) = try fixture(storeAccount: "owner-one@example.test")
        let (second, _, redownload) = try fixture(storeAccount: "owner-one@example.test", artwork: "alternate")
        let (third, _, otherAccount) = try fixture(storeAccount: "owner-two@example.test")
        defer { withExtendedLifetime((first, second, third)) {} }
        XCTAssertNotEqual(try Data(contentsOf: original), try Data(contentsOf: redownload))
        let tool = URL(fileURLWithPath: "/test/ipatool")
        var package = redownload
        let runner = FakeRunner { request in
            guard request.executable == tool else { return try ProcessRunner().run(request) }
            let output = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            try FileManager.default.copyItem(at: package, to: output)
            return CommandResult(exitCode: 0)
        }
        let target = AppLibrary(root: library.root, runner: runner)
        let app = StoreApp(id: 42, bundleID: bundleID, name: "Test", version: "2.1")
        let existing = try library.importPackage(original)
        XCTAssertEqual(try target.downloadStoreApp(app, tool: tool).id, existing.id)
        XCTAssertEqual(try target.entries().count, 1)

        package = otherAccount
        XCTAssertNotEqual(try target.downloadStoreApp(app, tool: tool).id, existing.id)
        XCTAssertEqual(try target.entries().count, 2)
    }

    func testFailedStoreDownloadDoesNotExposeRawOutputOrKeepPartialIPA() throws {
        let f = try Fixture()
        let root = f.base.appendingPathComponent("library")
        let tool = URL(fileURLWithPath: "/test/ipatool")
        let runner = FakeRunner { request in
            let output = try XCTUnwrap(request.arguments.last) + ".tmp"
            try Data("partial".utf8).write(to: URL(fileURLWithPath: output))
            return CommandResult(exitCode: 1, stderr: Data("license is required for private@example.test".utf8))
        }
        let target = AppLibrary(root: root, runner: runner)
        let app = StoreApp(id: 42, bundleID: bundleID, name: "Test", version: "2.1")
        XCTAssertThrowsError(try target.downloadStoreApp(app, tool: tool)) {
            XCTAssertTrue($0.localizedDescription.contains("лицензия"))
            XCTAssertFalse($0.localizedDescription.contains("private@example.test"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testInstallationRequiresConfirmationAndDeviceVerification() throws {
        let (f, library, package) = try fixture()
        let saved = try library.importPackage(package)
        let id = "00008101-1234567890123456"
        let device = try Device(udid: id, transport: .usb)
        let attributes = ["CFBundleIdentifier": bundleID, "CFBundleDisplayName": "Example Test",
                          "CFBundleShortVersionString": "2.1", "CFBundleVersion": "13"]
        var lists = 0
        var reportInstalled = false
        var reportedBuild = "13"
        let runner = FakeRunner { request in
            XCTAssertEqual(Array(request.arguments.prefix(2)), ["--udid", id])
            if request.arguments.contains("validate") { return CommandResult(exitCode: 0) }
            if request.arguments.contains("list") {
                XCTAssertTrue(request.arguments.contains("--bundle-identifier"))
                lists += 1
                var reported = attributes
                reported["CFBundleVersion"] = reportedBuild
                return try plistResult(reportInstalled && lists == 2 ? [reported] : [])
            }
            XCTAssertTrue(request.arguments.contains("install"))
            return CommandResult(exitCode: 0)
        }
        let service = try serviceFixture(f, runner: runner)
        XCTAssertThrowsError(try service.installApp(saved, from: library, on: device, confirmed: false))
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertThrowsError(try service.installApp(saved, from: library, on: device, confirmed: true))
        XCTAssertEqual(lists, 2)
        reportInstalled = true
        lists = 0
        reportedBuild = "12"
        XCTAssertThrowsError(try service.installApp(saved, from: library, on: device, confirmed: true))
        lists = 0
        reportedBuild = "13"
        XCTAssertNoThrow(try service.installApp(saved, from: library, on: device, confirmed: true))
        XCTAssertEqual(lists, 2)
    }

    func testBatchInstallationConfirmsMatchingBuildsAndContinuesAfterAConflict() throws {
        let (first, library, conflictIPA) = try fixture(packageBundleID: "com.example.conflict")
        let (second, _, matchingIPA) = try fixture(packageBundleID: "com.example.matching")
        let (third, _, newIPA) = try fixture(packageBundleID: "com.example.new")
        defer { withExtendedLifetime((first, second, third)) {} }
        let conflict = try library.importPackage(conflictIPA)
        let matching = try library.importPackage(matchingIPA)
        let new = try library.importPackage(newIPA)
        let device = try Device(udid: "00008101-1234567890123456", transport: .usb)
        var installations: [String] = []
        let runner = FakeRunner { request in
            XCTAssertEqual(Array(request.arguments.prefix(2)), ["--udid", device.udid])
            if request.arguments.contains("validate") { return CommandResult(exitCode: 0) }
            if request.arguments.contains("install") {
                let path = try XCTUnwrap(request.arguments.last)
                installations.append(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent)
                return CommandResult(exitCode: 0)
            }
            let selector = try XCTUnwrap(request.arguments.firstIndex(of: "--bundle-identifier"))
            let id = request.arguments[selector + 1]
            let apps = id == new.bundleID && installations.isEmpty ? [] : [[
                "CFBundleIdentifier": id, "CFBundleShortVersionString": "2.1",
                "CFBundleVersion": id == conflict.bundleID ? "12" : "13"
            ]]
            return try plistResult(apps)
        }
        let service = try serviceFixture(first, runner: runner)
        let token = CancellationToken()
        XCTAssertThrowsError(try library.installApps([conflict, matching, new], on: device, service: service,
                                                     confirmed: false, cancellation: token) { _, _ in })
        XCTAssertThrowsError(try library.installApps([matching, matching], on: device, service: service,
                                                     confirmed: true, cancellation: token) { _, _ in })
        XCTAssertTrue(runner.calls.isEmpty)

        var progress: [Int] = []
        let result = try library.installApps([conflict, matching, new], on: device, service: service,
                                             confirmed: true, cancellation: token) { index, _ in progress.append(index) }
        XCTAssertEqual(progress, [1, 2, 3])
        XCTAssertEqual(installations, [new.id])
        XCTAssertEqual(result.completed.map(\.id), [matching.id, new.id])
        XCTAssertEqual(result.failures.count, 1)
    }
}
