import TestSupport
import Foundation
import CryptoKit
@testable import IControlCore

final class ProcessAndCredentialTests: TestCase {
    func testLargeInputAndOutputAreDrainedConcurrently() throws {
        let data = Data(repeating: 71, count: 3 * 1024 * 1024)
        let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: data, timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, data.prefix(2 * 1024 * 1024))
        let failed = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'problem' >&2; exit 17"])
        XCTAssertEqual(failed.status, 17); XCTAssertEqual(failed.errorText, "problem")
    }
    func testTimeoutAndCancellationTerminateOnlyTheOwnedProcess() throws {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 0.15))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        let token = CancellationToken(), done = expectation(description: "cancelled")
        DispatchQueue.global().async {
            do {
                _ = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 30, cancellation: token)
                XCTFail("Cancelled process unexpectedly succeeded")
            } catch { }
            done.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        wait(for: [done], timeout: 3)
    }
    func testNativeAskpassRequiresTokenAndPasswordPrompt() throws {
        let broker = try AskpassServer(password: "fixture-secret")
        defer { broker.stop() }
        var environment = ["ICONTROL_ASKPASS_SOCKET": broker.path, "ICONTROL_ASKPASS_TOKEN": broker.token]
        XCTAssertEqual(try AskpassServer.reply(environment: environment, prompt: "root@localhost's password:"), "fixture-secret")
        XCTAssertThrowsError(try AskpassServer.reply(environment: environment, prompt: "Are you sure you want to continue connecting?"))
        environment["ICONTROL_ASKPASS_TOKEN"] = "wrong-token"
        XCTAssertThrowsError(try AskpassServer.reply(environment: environment, prompt: "Password:"))
        broker.stop()
        eventually { !FileManager.default.fileExists(atPath: broker.path) }
    }
    func testPackageHashRejectsCorruptFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("package fixture".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let package = ServerPackage(filename: "fixture.deb", sha256: digest, architecture: "iphoneos-arm64")
        try bytes.write(to: directory.appendingPathComponent(package.filename))
        XCTAssertEqual(try package.verifiedData(in: directory), bytes)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(package.filename))
        XCTAssertThrowsError(try package.verifiedData(in: directory))
    }
    func testTrustResetPreservesOtherDevices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = SSHTrust.alias(for: "target"), other = SSHTrust.alias(for: "other")
        let file = directory.appendingPathComponent("known_hosts")
        try "# comment\n\(target) ssh-ed25519 AAAA\n\(other) ssh-ed25519 BBBB\n".write(to: file, atomically: true, encoding: .utf8)
        try SSHTrust.reset(device: "target", supportDirectory: directory)
        let contents = try String(contentsOf: file)
        XCTAssertFalse(contents.contains(target)); XCTAssertTrue(contents.contains(other)); XCTAssertTrue(contents.contains("# comment"))
    }
    func testRemoteScriptsAreValidPOSIXShell() throws {
        for script in [RemoteScripts.inspect, RemoteScripts.configure] {
            let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-n"], input: Data(script.utf8))
            XCTAssertEqual(result.status, 0, result.errorText)
        }
    }
}
