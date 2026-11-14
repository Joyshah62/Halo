// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "HaloCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "HaloCore", targets: ["HaloCore"]), .executable(name: "HaloCoreChecks", targets: ["HaloCoreChecks"])],
    targets: [
        .target(name: "HaloCore"),
        .executableTarget(name: "HaloCoreChecks", dependencies: ["HaloCore"], path: "Tests/HaloCoreTests")
    ]
)
