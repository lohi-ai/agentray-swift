// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentRay",
    platforms: [.iOS(.v13), .macOS(.v11), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "AgentRay", targets: ["AgentRay"]),
    ],
    targets: [
        .target(name: "AgentRay"),
        .testTarget(name: "AgentRayTests", dependencies: ["AgentRay"]),
    ]
)
