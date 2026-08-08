// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BeaconAgentKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
        .tvOS(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "BeaconAgentCore", targets: ["BeaconAgentCore"]),
        .library(name: "BeaconAgentSwiftUI", targets: ["BeaconAgentSwiftUI"]),
        .library(name: "BeaconAgentAGUI", targets: ["BeaconAgentAGUI"]),
        .library(name: "BeaconAgentA2UI", targets: ["BeaconAgentA2UI"]),
        .library(name: "BeaconAgentDevice", targets: ["BeaconAgentDevice"]),
        .library(name: "BeaconAgentMCP", targets: ["BeaconAgentMCP"]),
        .library(name: "BeaconAgentAppleEvents", targets: ["BeaconAgentAppleEvents"])
    ],
    targets: [
        .target(name: "BeaconAgentCore"),
        .target(name: "BeaconAgentSwiftUI", dependencies: ["BeaconAgentCore", "BeaconAgentA2UI"]),
        .target(name: "BeaconAgentAGUI", dependencies: ["BeaconAgentCore"]),
        .target(name: "BeaconAgentA2UI", dependencies: ["BeaconAgentCore"]),
        .target(name: "BeaconAgentDevice", dependencies: ["BeaconAgentCore"]),
        .target(name: "BeaconAgentMCP", dependencies: ["BeaconAgentCore", "BeaconAgentA2UI"]),
        .target(name: "BeaconAgentAppleEvents", dependencies: ["BeaconAgentCore"]),
        .testTarget(name: "BeaconAgentCoreTests", dependencies: ["BeaconAgentCore"]),
        .testTarget(name: "BeaconAgentAGUITests", dependencies: ["BeaconAgentAGUI", "BeaconAgentCore"]),
        .testTarget(name: "BeaconAgentA2UITests", dependencies: ["BeaconAgentA2UI", "BeaconAgentCore"]),
        .testTarget(name: "BeaconAgentDeviceTests", dependencies: ["BeaconAgentDevice", "BeaconAgentCore"]),
        .testTarget(name: "BeaconAgentMCPTests", dependencies: ["BeaconAgentMCP", "BeaconAgentA2UI", "BeaconAgentCore"]),
        .testTarget(name: "BeaconAgentSwiftUITests", dependencies: ["BeaconAgentSwiftUI", "BeaconAgentA2UI", "BeaconAgentCore"]),
        .testTarget(name: "BeaconAgentAppleEventsTests", dependencies: ["BeaconAgentAppleEvents", "BeaconAgentCore"])
    ],
    swiftLanguageModes: [.v6]
)
