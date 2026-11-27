// swift-tools-version: 5.10
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
// Prepared by Scripts/build-input-core.sh. Keep these flags on the bridge so
// *every* final product that depends on IControlCore links the same archive.
let profiles: [(String, BuildConfiguration)] = [("debug", .debug), ("release", .release)]
func rustOutput(_ profile: String) -> String {
    root.appendingPathComponent("work/rust-input/\(profile)").path
}
let bridge = Target.target(
    name: "CRustInput", publicHeadersPath: "include",
    // SwiftPM doesn't otherwise track an external .a as an incremental input.
    cSettings: profiles.map { profile, config in
        .unsafeFlags(["-include", "\(rustOutput(profile))/build-stamp.h"], .when(configuration: config))
    },
    linkerSettings: profiles.map { profile, config in
        .unsafeFlags(["-Xlinker", "\(rustOutput(profile))/libicontrol_input.a"], .when(configuration: config))
    }
)

let package = Package(
    name: "iControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IControlCore", targets: ["IControlCore"]),
        .executable(name: "iControl", targets: ["IControlApp"]),
        .executable(name: "iControlSimulator", targets: ["IControlSimulator"])
    ],
    targets: [
        .target(name: "CTransport", publicHeadersPath: "include"),
        bridge,
        .target(name: "IControlCore", dependencies: ["CTransport", "CRustInput"]),
        .executableTarget(name: "IControlApp", dependencies: ["IControlCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "IControlSimulator", dependencies: ["IControlCore", "CTransport"], path: "Tools/Simulator")
    ]
)

// Some source distributions omit the legacy validation executable and fixtures.
// A partial fixture tree should still fail the build instead of hiding a test.
if ["Tests/TestSupport", "Tests/IControlCoreTests"].contains(where: {
    FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
}) {
    package.products.append(.executable(name: "iControlValidation", targets: ["IControlValidation"]))
    package.targets += [
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .executableTarget(name: "IControlValidation", dependencies: ["IControlCore", "CTransport", "TestSupport"], path: "Tests/IControlCoreTests")
    ]
}
