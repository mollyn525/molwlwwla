// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BaduanjinCore", platforms: [.macOS(.v13), .iOS(.v17)], products: [.library(name: "BaduanjinCore", targets: ["BaduanjinCore"])], targets: [
    .target(name: "BaduanjinCore", path: "Sources/Core"),
    .testTarget(name: "BaduanjinCoreTests", dependencies: ["BaduanjinCore"], path: "Tests", resources: [.copy("Fixtures")])
])
