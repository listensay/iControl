import TestSupport
import Foundation
import CryptoKit
@testable import IControlCore

/// Executes the actual installation script against a temporary filesystem and
/// fake iPad commands. It never uses the host's dpkg, launchctl, or chown.
private final class FakeRemote {
    let root: URL
    let prefix: URL
    let stage: URL
    let state: URL
    let configuration: URL
    let daemon: URL
    let script: URL
    let log: URL
    let hash: String
    private let fakeBin: URL
    init(original: Data? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ic-script-" + UUID().uuidString)
        prefix = root.appendingPathComponent("var-jb"); stage = root.appendingPathComponent("stage")
        state = root.appendingPathComponent("state"); fakeBin = root.appendingPathComponent("commands")
        configuration = prefix.appendingPathComponent("Library/PreferenceBundles/TrollVNCPrefs.bundle/Managed.plist")
        daemon = prefix.appendingPathComponent("Library/LaunchDaemons/com.82flex.trollvnc.plist")
        script = stage.appendingPathComponent("configure.sh"); log = root.appendingPathComponent("actions.log")
        let package = Data("test package bytes".utf8)
        hash = SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined()
        for directory in [prefix.appendingPathComponent("usr/bin"), stage, fakeBin, configuration.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if let original { try original.write(to: configuration) }
        try package.write(to: stage.appendingPathComponent("server.deb"))
        try ServerConfiguration.plist(password: "Abcd2345").write(to: stage.appendingPathComponent("Managed.plist"))
        let adapted = RemoteScripts.configure
            .replacingOccurrences(of: "/var/mobile/Library/iControl", with: state.path)
            .replacingOccurrences(of: "/var/jb", with: prefix.path)
            .replacingOccurrences(of: "PATH=", with: "PATH=\(fakeBin.path):")
        XCTAssertFalse(adapted.contains("/var/mobile/Library/iControl"))
        XCTAssertFalse(adapted.contains("/var/jb"))
        try Data(adapted.utf8).write(to: script)
        try executable("id", contents: "#!/bin/sh\nprintf '0\\n'\n")
        try executable("chown", contents: "#!/bin/sh\nexit 0\n")
        try executable("launchctl", contents: #"""
        #!/bin/sh
        printf 'launchctl %s\n' "$*" >> "$TEST_LOG"
        case "$1" in
          print)
            case "$*" in *com.icontrol.fpsd*) [ "${TEST_FPS_WAS_RUNNING:-0}" = 1 ] && echo ' pid = 123' ;; *) [ "${TEST_WAS_RUNNING:-0}" = 1 ] ;; esac ;;
          bootstrap|load)
            case "$*" in *com.icontrol.fpsd*)
              if [ "${TEST_NEW_FPS_FAIL:-0}" = 1 ] && grep -q 'test FPS' "$TEST_PREFIX/usr/local/libexec/icontrol-fpsd"; then exit 1; fi
              [ "${TEST_FPS_START_FAIL:-0}" != 1 ] ;; *) [ "${TEST_START_FAIL:-0}" != 1 ] ;; esac ;;
          *) exit 0 ;;
        esac
        """#)
        let dpkg = #"""
        #!/bin/sh
        case "$1" in
          --print-architecture) printf 'iphoneos-arm64\n' ;;
          --compare-versions) if [ "$3" = lt ] && [ "${TEST_INSTALLED:-}" = '99.0' ]; then exit 1; else exit 0; fi ;;
          -i)
            printf 'dpkg-install\n' >> "$TEST_LOG"
            [ "${TEST_INSTALL_FAIL:-0}" != 1 ] || exit 41
            mkdir -p "$TEST_PREFIX/Library/LaunchDaemons"
            touch "$TEST_PREFIX/Library/LaunchDaemons/com.82flex.trollvnc.plist" "$TEST_PREFIX/usr/bin/trollvncserver"
            chmod 755 "$TEST_PREFIX/usr/bin/trollvncserver"
            ;;
          *) exit 42 ;;
        esac
        """#
        try Data(dpkg.utf8).write(to: prefix.appendingPathComponent("usr/bin/dpkg"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prefix.appendingPathComponent("usr/bin/dpkg").path)
        let query = #"""
        #!/bin/sh
        case "$*" in
          *preferenceloader*) printf 'install ok installed' ;;
          *firmware*) printf '17.7.11' ;;
          *com.82flex.trollvnc*) if [ -n "${TEST_INSTALLED:-}" ]; then printf '%s' "$TEST_INSTALLED"; else exit 1; fi ;;
        esac
        """#
        try Data(query.utf8).write(to: prefix.appendingPathComponent("usr/bin/dpkg-query"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prefix.appendingPathComponent("usr/bin/dpkg-query").path)
    }
    private func executable(_ name: String, contents: String) throws {
        let file = fakeBin.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    func existingDaemon() throws {
        try FileManager.default.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: daemon)
        let binary = prefix.appendingPathComponent("usr/bin/trollvncserver")
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }
    var fpsBinary: URL { prefix.appendingPathComponent("usr/local/libexec/icontrol-fpsd") }
    var fpsJob: URL { prefix.appendingPathComponent("Library/LaunchDaemons/com.icontrol.fpsd.plist") }
    var fpsToken: URL { state.appendingPathComponent("fps-token") }
    func addFPSPayload() throws {
        try Data(RemoteFPSScripts.functions.utf8).write(to: stage.appendingPathComponent("fps-functions.sh"))
        let bytes = Data("#!/bin/sh\necho 'test FPS daemon executable'\n".utf8)
        try bytes.write(to: stage.appendingPathComponent("icontrol-fpsd"))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try Data(digest.utf8).write(to: stage.appendingPathComponent("fps-sha256"))
        try FPSDaemonPackage.launchPlist(prefix: "/var/jb").write(to: stage.appendingPathComponent("FPSDaemon.plist"))
        try Data(String(repeating: "a5", count: 32).utf8).write(to: stage.appendingPathComponent("fps-token"))
    }
    func addExistingFPS() throws {
        for file in [fpsBinary, fpsJob, fpsToken] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("original " + file.lastPathComponent).utf8).write(to: file)
        }
    }
    func prepareManagedFPSUpdate() throws -> String {
        try addFPSPayload(); try addExistingFPS()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fpsBinary.path)
        try Data("managed".utf8).write(to: state.appendingPathComponent("fps-managed-by-icontrol"))
        // A standalone update does not upload a new job, token, or VNC configuration.
        for file in ["FPSDaemon.plist", "fps-token", "Managed.plist", "server.deb"] {
            try FileManager.default.removeItem(at: stage.appendingPathComponent(file))
        }
        return try String(contentsOf: stage.appendingPathComponent("fps-sha256"))
    }
    func run(action: String = "install", expectedHash: String? = nil, options: [String: String] = [:]) throws -> ProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment["TEST_PREFIX"] = prefix.path; environment["TEST_LOG"] = log.path
        environment.merge(options) { _, new in new }
        return try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path, stage.path, "iphoneos-arm64", expectedHash ?? hash, action], environment: environment, timeout: 15)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

final class InstallationScriptTests: TestCase {
    func testInstallationBacksUpConfigurationAndRestoreReturnsOriginal() throws {
        let original = Data("original managed configuration".utf8)
        let remote = try FakeRemote(original: original)
        defer { remote.cleanup() }
        let installed = try remote.run()
        XCTAssertEqual(installed.status, 0, installed.errorText)
        XCTAssertTrue(installed.outputText.contains("ICONTROL:DONE=installed"))
        XCTAssertEqual(try Data(contentsOf: remote.state.appendingPathComponent("Managed.original.plist")), original)
        XCTAssertEqual(try Data(contentsOf: remote.configuration), try Data(contentsOf: remote.stage.appendingPathComponent("Managed.plist")))
        let restored = try remote.run(action: "restore")
        XCTAssertEqual(restored.status, 0, restored.errorText)
        XCTAssertEqual(try Data(contentsOf: remote.configuration), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.state.appendingPathComponent("managed-by-icontrol").path))
    }
    func testFailedPackageInstallationRollsBackConfiguration() throws {
        let original = Data("previous settings".utf8)
        let remote = try FakeRemote(original: original)
        defer { remote.cleanup() }
        try remote.existingDaemon()
        let result = try remote.run(options: ["TEST_INSTALL_FAIL": "1", "TEST_WAS_RUNNING": "1"])
        XCTAssertEqual(result.status, 41)
        XCTAssertEqual(try Data(contentsOf: remote.configuration), original)
        XCTAssertFalse(result.outputText.contains("ICONTROL:DONE=installed"))
        XCTAssertTrue(result.errorText.contains("已恢复"))
    }
    func testExistingNewerVersionIsConfiguredWithoutDowngrade() throws {
        let remote = try FakeRemote()
        defer { remote.cleanup() }
        try remote.existingDaemon()
        let result = try remote.run(options: ["TEST_INSTALLED": "99.0"])
        XCTAssertEqual(result.status, 0, result.errorText)
        let actions = try String(contentsOf: remote.log)
        XCTAssertFalse(actions.contains("dpkg-install"))
        let restored = try remote.run(action: "restore")
        XCTAssertEqual(restored.status, 0, restored.errorText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.configuration.path))
    }
    func testFailedRestoreKeepsCurrentConfigurationAndBackup() throws {
        let remote = try FakeRemote(original: Data("original".utf8))
        defer { remote.cleanup() }
        XCTAssertEqual(try remote.run().status, 0)
        let configured = try Data(contentsOf: remote.configuration)
        let result = try remote.run(action: "restore", options: ["TEST_START_FAIL": "1"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try Data(contentsOf: remote.configuration), configured)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.state.appendingPathComponent("managed-by-icontrol").path))
    }

    func testFPSInstallReinstallAndRestoreOriginalFiles() throws {
        let remote = try FakeRemote(original: Data("original video configuration".utf8))
        defer { remote.cleanup() }
        try remote.addFPSPayload(); try remote.addExistingFPS()
        let originals = try [remote.fpsBinary, remote.fpsJob, remote.fpsToken].map { try Data(contentsOf: $0) }
        XCTAssertEqual(try remote.run(options: ["TEST_FPS_WAS_RUNNING": "1"]).status, 0)
        XCTAssertEqual(try Data(contentsOf: remote.fpsBinary), try Data(contentsOf: remote.stage.appendingPathComponent("icontrol-fpsd")))
        let mode = try FileManager.default.attributesOfItem(atPath: remote.fpsToken.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try Data(String(repeating: "b6", count: 32).utf8).write(to: remote.stage.appendingPathComponent("fps-token"))
        XCTAssertEqual(try remote.run(options: ["TEST_INSTALLED": "99.0", "TEST_FPS_WAS_RUNNING": "1"]).status, 0)
        let restored = try remote.run(action: "restore", options: ["TEST_FPS_WAS_RUNNING": "1"])
        XCTAssertEqual(restored.status, 0, restored.errorText)
        XCTAssertEqual(try [remote.fpsBinary, remote.fpsJob, remote.fpsToken].map { try Data(contentsOf: $0) }, originals)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.state.appendingPathComponent("fps-managed-by-icontrol").path))
        XCTAssertEqual(try Data(contentsOf: remote.configuration), Data("original video configuration".utf8))
    }

    func testFPSStartFailureRollsBackBothServices() throws {
        let remote = try FakeRemote(original: Data("original video".utf8))
        defer { remote.cleanup() }
        try remote.addFPSPayload(); try remote.addExistingFPS(); try remote.existingDaemon()
        let before = try [remote.fpsBinary, remote.fpsJob, remote.fpsToken].map { try Data(contentsOf: $0) }
        let result = try remote.run(options: ["TEST_FPS_START_FAIL": "1", "TEST_WAS_RUNNING": "1", "TEST_FPS_WAS_RUNNING": "1"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try [remote.fpsBinary, remote.fpsJob, remote.fpsToken].map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(try Data(contentsOf: remote.configuration), Data("original video".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.state.appendingPathComponent("fps-managed-by-icontrol").path))
    }

    func testFPSFirstInstallFailureLeavesNoFilesAndRestoreRemovesNewDaemon() throws {
        let remote = try FakeRemote(); defer { remote.cleanup() }
        try remote.addFPSPayload()
        XCTAssertNotEqual(try remote.run(options: ["TEST_FPS_START_FAIL": "1"]).status, 0)
        for file in [remote.fpsBinary, remote.fpsJob, remote.fpsToken] { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertEqual(try remote.run().status, 0)
        XCTAssertEqual(try remote.run(action: "restore").status, 0)
        for file in [remote.fpsBinary, remote.fpsJob, remote.fpsToken] { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
    }

    func testFPSRestoreFailureKeepsCurrentVideoInputAndBackups() throws {
        let remote = try FakeRemote(original: Data("original video".utf8)); defer { remote.cleanup() }
        try remote.addFPSPayload(); try remote.addExistingFPS()
        XCTAssertEqual(try remote.run(options: ["TEST_FPS_WAS_RUNNING": "1"]).status, 0)
        let before = try [remote.configuration, remote.fpsBinary, remote.fpsJob, remote.fpsToken].map { try Data(contentsOf: $0) }
        let result = try remote.run(action: "restore", options: ["TEST_FPS_START_FAIL": "1", "TEST_FPS_WAS_RUNNING": "1"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try [remote.configuration, remote.fpsBinary, remote.fpsJob, remote.fpsToken].map { try Data(contentsOf: $0) }, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.state.appendingPathComponent("fps-managed-by-icontrol").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.state.appendingPathComponent("managed-by-icontrol").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.state.appendingPathComponent("fps-original/token").path))
    }

    func testFPSPayloadCorruptionStopsBeforeVideoMutation() throws {
        let remote = try FakeRemote(original: Data("original video".utf8)); defer { remote.cleanup() }
        try remote.addFPSPayload()
        try Data("tampered executable".utf8).write(to: remote.stage.appendingPathComponent("icontrol-fpsd"))
        let result = try remote.run()
        XCTAssertEqual(result.status, 44)
        XCTAssertEqual(try Data(contentsOf: remote.configuration), Data("original video".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.fpsBinary.path))
    }

    func testStandaloneFPSUpdateKeepsOtherFilesAndServices() throws {
        let remote = try FakeRemote(original: Data("video settings".utf8)); defer { remote.cleanup() }
        let digest = try remote.prepareManagedFPSUpdate()
        let untouched = [remote.configuration, remote.fpsToken, remote.fpsJob, remote.state.appendingPathComponent("fps-managed-by-icontrol")]
        let previous = try untouched.map { try Data(contentsOf: $0) }
        let result = try remote.run(action: "update-fps", expectedHash: digest, options: ["TEST_FPS_WAS_RUNNING": "1"])
        XCTAssertEqual(result.status, 0, result.errorText)
        XCTAssertTrue(result.outputText.contains("ICONTROL:DONE=fps-updated"))
        XCTAssertEqual(try Data(contentsOf: remote.fpsBinary), try Data(contentsOf: remote.stage.appendingPathComponent("icontrol-fpsd")))
        XCTAssertEqual(try untouched.map { try Data(contentsOf: $0) }, previous)
        let actions = try String(contentsOf: remote.log)
        XCTAssertFalse(actions.contains("com.82flex.trollvnc")); XCTAssertFalse(actions.contains("dpkg-install"))
    }

    func testStandaloneFPSUpdatePreflightAndRollback() throws {
        let remote = try FakeRemote(original: Data("video settings".utf8)); defer { remote.cleanup() }
        let digest = try remote.prepareManagedFPSUpdate()
        let files = [remote.fpsBinary, remote.configuration, remote.fpsToken, remote.fpsJob]
        let previous = try files.map { try Data(contentsOf: $0) }
        XCTAssertEqual(try remote.run(action: "update-fps", expectedHash: digest).status, 46)
        XCTAssertEqual(try remote.run(action: "update-fps", options: ["TEST_FPS_WAS_RUNNING": "1"]).status, 44)
        XCTAssertFalse(try String(contentsOf: remote.log).contains("bootout"))
        let result = try remote.run(action: "update-fps", expectedHash: digest, options: ["TEST_FPS_WAS_RUNNING": "1", "TEST_NEW_FPS_FAIL": "1"])
        XCTAssertNotEqual(result.status, 0); XCTAssertTrue(result.errorText.contains("已换回"))
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, previous)
        XCTAssertFalse(try String(contentsOf: remote.log).contains("com.82flex.trollvnc"))
    }
}
