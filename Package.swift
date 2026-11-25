// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IControlCore", targets: ["IControlCore"]),
        .executable(name: "iControl", targets: ["IControlApp"]),
        .executable(name: "iControlValidation", targets: ["IControlValidation"]),
        .executable(name: "iControlSimulator", targets: ["IControlSimulator"])
    ],
    targets: [
        .target(name: "CTransport", publicHeadersPath: "include"),
        .target(name: "IControlCore", dependencies: ["CTransport"]),
        .executableTarget(name: "IControlApp", dependencies: ["IControlCore"], resources: [.copy("Resources")]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .executableTarget(name: "IControlSimulator", dependencies: ["IControlCore", "CTransport"], path: "Tools/Simulator"),
        .executableTarget(name: "IControlValidation", dependencies: ["IControlCore", "CTransport", "TestSupport"], path: "Tests/IControlCoreTests")
    ]
)
