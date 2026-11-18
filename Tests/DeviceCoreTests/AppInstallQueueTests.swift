import Foundation
import XCTest
@testable import DeviceCore

final class AppInstallQueueTests: XCTestCase {
    private func app(_ name: String) throws -> SavedApp {
        try JSONDecoder().decode(SavedApp.self, from: Data("""
        {
          "bundleID": "com.example.\(name)", "name": "\(name)", "version": "1", "build": "1",
          "digest": {"sha256": "\(name)", "bytes": 100}, "savedAt": 0
        }
        """.utf8))
    }

    func testActiveAttemptFinishesBeforePausingAndQueueKeepsUpdatedOrder() throws {
        let (a, b, c, d, e) = try (app("a"), app("b"), app("c"), app("d"), app("e"))
        let phone = try Device(udid: "00008101-1234567890123456", transport: .usb)
        let otherPhone = try Device(udid: "00008101-AAAAAAAAAAAAAAAA", transport: .usb)
        var queue = AppInstallQueue()
        queue.enqueue([a, b, c, d], on: phone)
        let first = try XCTUnwrap(queue.startNext())
        XCTAssertEqual(first.app.id, a.id)
        queue.pauseReason = "Paused"
        queue.enqueue([b, e], on: phone)
        queue.enqueue([e], on: otherPhone)
        queue.moveWaiting(c.id, to: 0)
        queue.moveWaiting(e.id, to: 1)
        queue.removeWaiting(d.id)
        queue.removeWaiting(a.id)
        queue.update(.installing(percent: 46), attempt: first.attempt)
        XCTAssertEqual(queue.waiting.map(\.id), [c.id, e.id, b.id])
        XCTAssertEqual(queue.running?.state, .running(.installing(percent: 46)))

        queue.finish(.finished(.installed), attempt: first.attempt)
        XCTAssertNil(queue.startNext())
        queue.pauseReason = nil
        let second = try XCTUnwrap(queue.startNext())
        XCTAssertEqual(second.app.id, c.id)
        queue.update(.sendingPackage, attempt: first.attempt)
        XCTAssertEqual(queue.running?.state, .running(.checkingPackage))
        queue.finish(.failed("Test error"), attempt: second.attempt)
        queue.retry(c.id)
        XCTAssertEqual(queue.waiting.map(\.id), [e.id, b.id, c.id])
        XCTAssertEqual(queue.device, phone)
    }

    func testInstallerProgressArrivesAcrossChunkBoundariesBeforeExit() throws {
        let reported = LockedProgress()
        let release = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: release) }
        let afterProgress = DispatchSemaphore(value: 0)
        let processExited = expectation(description: "installer exited after progress")
        let reader = InstallerProgressReader { progress in
            reported.append(progress)
            if progress == .installing(percent: 46) { afterProgress.signal() }
        }
        let request = CommandRequest(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", """
            printf "Copying 'app.ipa' to device... "
            printf "DONE.\\nInstalling 'com.example.test'\\n\\rInstall: Installing (4"
            sleep 0.05
            printf '6%%)'
            while [ ! -f "$1" ]; do sleep 0.05; done
            """, "installer-test", release.path], timeout: 5, onStdout: { reader.append($0) })
        DispatchQueue.global().async {
            let result = try? ProcessRunner().run(request)
            XCTAssertEqual(result?.exitCode, 0)
            processExited.fulfill()
        }
        XCTAssertEqual(afterProgress.wait(timeout: .now() + 3), .success)
        try Data().write(to: release)
        wait(for: [processExited], timeout: 6)
        XCTAssertEqual(reported.values, [.sendingPackage, .installing(percent: nil), .installing(percent: 46)])
    }
}

private final class LockedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: [AppInstallProgress] = []

    var values: [AppInstallProgress] {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }

    func append(_ value: AppInstallProgress) {
        lock.lock()
        progress.append(value)
        lock.unlock()
    }
}
