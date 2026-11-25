import TestSupport
import Foundation
@testable import IControlCore

final class EnvironmentTests: TestCase {
    private func sample(architecture: String = "iphoneos-arm64", prefix: String = "/var/jb", preferenceLoader: String = "1") -> String {
        """
        A login banner is allowed.
        ICONTROL:ARCH=\(architecture)
        ICONTROL:PREFIX=\(prefix)
        ICONTROL:FIRMWARE=17.7.11
        ICONTROL:UID=501
        ICONTROL:SUDO=1
        ICONTROL:SUDO_NOPASS=0
        ICONTROL:PREFERENCELOADER=\(preferenceLoader)
        ICONTROL:FIRMWARE_SUPPORTED=1
        ICONTROL:INSTALLED=
        ICONTROL:MANAGED=0
        """
    }
    func testArchitectureChoosesRootlessOrRootfulAndRejectsMismatch() throws {
        let rootless = try InstallationEnvironment.parse(sample())
        XCTAssertEqual(rootless.mode, .rootless)
        XCTAssertEqual(ServerPackage.forEnvironment(rootless).architecture, "iphoneos-arm64")
        let rootful = try InstallationEnvironment.parse(sample(architecture: "iphoneos-arm", prefix: ""))
        XCTAssertEqual(rootful.mode, .rootful)
        XCTAssertEqual(ServerPackage.forEnvironment(rootful).architecture, "iphoneos-arm")
        XCTAssertThrowsError(try InstallationEnvironment.parse(sample(architecture: "iphoneos-arm64e")))
        XCTAssertThrowsError(try InstallationEnvironment.parse(sample(architecture: "iphoneos-arm", prefix: "/var/jb")))
        XCTAssertThrowsError(try InstallationEnvironment.parse(sample() + "\nICONTROL:UID=0"))
    }
    func testMissingDependencyPreventsInstallation() throws {
        let environment = try InstallationEnvironment.parse(sample(preferenceLoader: "0"))
        XCTAssertFalse(environment.canInstall)
        XCTAssertTrue(environment.requirements.contains { $0.contains("PreferenceLoader") })
    }
    func testConfigurationLimitsServiceToUSBAndDisablesUnneededServices() throws {
        let data = try ServerConfiguration.plist(password: "Abcd2345")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(plist["BindHost"] as? String, "127.0.0.1")
        XCTAssertEqual(plist["Port"] as? Int, 5901)
        XCTAssertEqual(plist["BonjourEnabled"] as? Bool, false)
        XCTAssertEqual(plist["HttpPort"] as? Int, 0)
        XCTAssertEqual(plist["KeyLogging"] as? Bool, false)
        XCTAssertThrowsError(try ServerConfiguration.plist(password: "too-long-password"))
        XCTAssertThrowsError(try ServerConfiguration.plist(password: "中文密码1234"))
        XCTAssertThrowsError(try ServerConfiguration.plist(password: "Abcd2345", scale: 2))
    }
    func testCredentialsRejectShellInjectionAndPasswordLineBreaks() {
        XCTAssertThrowsError(try SSHCredentials(username: "root; whoami", password: "x"))
        XCTAssertThrowsError(try SSHCredentials(username: "root", password: "x\ny"))
        XCTAssertEqual(shellQuote("a'b $() `text`"), "'a'\\''b $() `text`'")
    }
}
