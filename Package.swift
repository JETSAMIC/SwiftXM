// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftXM",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftXM", targets: ["SwiftXM"])
    ],
    targets: [
        .target(name: "SwiftXM"),
        .testTarget(name: "SwiftXMTests", dependencies: ["SwiftXM"])
    ]
)
