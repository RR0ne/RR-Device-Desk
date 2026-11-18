import Foundation
@testable import DeviceCore
import XCTest

final class StoreAuthenticationTests: XCTestCase {
    private func engine(_ fixture: Fixture, _ script: String) throws -> StoreAuthentication {
        let executable = fixture.base.appendingPathComponent("store-engine")
        try Data(("#!/bin/sh\nset -eu\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return StoreAuthentication(executable: executable)
    }

    func testPasswordAndCodeTravelOnlyOnPipeAndOnlyAfterPrompts() throws {
        let f = try Fixture()
        let session = try engine(f, #"""
        test "$#" = 5
        test "$*" = '--format json auth login --prepare-first'
        printf '%s\n' 'enter Apple ID (email address or phone number):' >&2
        IFS= read -r account
        test "$account" = 'synthetic@example.test'
        printf '%s\n' 'enter password:' >&2
        IFS= read -r secret
        test "$secret" = 'a password with spaces '
        printf '%s\n' '{"event":"verification-fallback","httpStatus":200}'
        printf '%s\n' 'enter 2FA code:' >&2
        IFS= read -r code
        test "$code" = 123456
        printf '%s\n' '{"success":true,"email":"synthetic@example.test"}'
        """#)
        var requestedCode = false
        let account = try session.logIn(cancellation: CancellationToken(), credentials: {
            ("synthetic@example.test", "a password with spaces ")
        }, verificationCode: { status in
            XCTAssertEqual(status, 200)
            XCTAssertFalse(requestedCode)
            requestedCode = true
            return "123456"
        })
        XCTAssertTrue(requestedCode)
        XCTAssertEqual(account.email, "synthetic@example.test")
    }

    func testSignInFailureDoesNotExposeRawReply() throws {
        let f = try Fixture()
        let session = try engine(f, #"""
        printf '%s\n' 'enter Apple ID (email address or phone number):' >&2
        IFS= read -r account
        printf '%s\n' 'enter password:' >&2
        IFS= read -r secret
        printf '%s\n' '{"success":false,"error":"incorrect password: sensitive-reply"}'
        exit 1
        """#)
        XCTAssertThrowsError(try session.logIn(cancellation: CancellationToken(), credentials: {
            ("synthetic@example.test", "fake")
        }, verificationCode: { _ in
            XCTFail("A failed password must not prompt for a new code")
            return "123456"
        })) {
            XCTAssertTrue($0.localizedDescription.contains("Apple отклонила вход"))
            XCTAssertFalse($0.localizedDescription.contains("sensitive-reply"))
        }
    }

    func testEmptySessionCanBeDetectedAndCleared() throws {
        let f = try Fixture()
        let session = try engine(f, #"""
        case "$*" in
            *'auth info')
                printf '%s\n' '{"success":false,"error":"failed to get account: key not found"}'
                exit 1 ;;
            *'auth revoke') printf '%s\n' '{"success":true}'; exit 0 ;;
        esac
        exit 2
        """#)
        XCTAssertNil(try session.account())
        XCTAssertNoThrow(try session.signOut())
    }

    func testLogoutRequiresSuccessfulCleanup() throws {
        let f = try Fixture()
        let session = try engine(f, #"""
        printf '%s\n' '{"success":false,"error":"key not found; cleanup failed"}'
        exit 1
        """#)
        XCTAssertThrowsError(try session.signOut())
    }

    func testPreparationFailuresIdentifyStageWithoutExposingServerReply() throws {
        let cases = [
            ("net/http: TLS handshake timeout", "Сервер подготовки входа Apple"),
            ("anisette provisioning returned HTTP 401 (Apple code -27677)", "завершающий запрос подготовки входа (HTTP 401, код Apple -27677)"),
            ("anisette provisioning returned HTTP 502", "временно недоступен (HTTP 502)")
        ]
        for (reply, expectedMessage) in cases {
            let f = try Fixture()
            let session = try engine(f, #"""
            printf '%s\n' '{"success":false,"error":"prepare Apple authentication: finish machine provisioning: request private-url-token: \#(reply)"}'
            exit 1
            """#)
            XCTAssertThrowsError(try session.logIn(cancellation: CancellationToken(), credentials: {
                XCTFail("Preparation failure cannot ask for account credentials")
                return ("synthetic@example.test", "fake")
            }, verificationCode: { _ in
                XCTFail("Preparation failure cannot ask for a verification code")
                return "123456"
            })) {
                XCTAssertTrue($0.localizedDescription.contains(expectedMessage))
                XCTAssertFalse($0.localizedDescription.contains("private-url-token"))
            }
        }
    }
}
