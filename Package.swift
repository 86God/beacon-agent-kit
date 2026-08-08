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
        .library(name: "BeaconAgentDevice", targets: ["BeaconAgentDevice"]),
        .library(name: "BeaconAgentAppleEvents", targets: ["BeaconAgentAppleEvents"])
    ],
    targets: [
        .target(name: "BeaconAgentCore"),
        .target(name: "BeaconAgentSwiftUI", dependencies: ["BeaconAgentCore"]),
        .target(name: "BeaconAgentAGUI", dependencies: ["BeaconAgentCore"]),
        .target(name: "BeaconAgentDevice", dependencies: ["BeaconAgentCore"]),
        .target(name: "BeaconAgentAppleEvents", dependencies: ["BeaconAgentCore"]),
        .testTarget(name: "BeaconAgentCoreTests", dependencies: ["BeaconAgentCore"]),
        .testTarget(name: "BeaconAgentAGUITests", dependencies: ["BeaconAgentAGUI", "BeaconAgentCore"]),
        .testTarget(name: "BeaconAgentDeviceTests", dependencies: ["BeaconAgentDevice", "BeaconAgentCore"]),
        .testTarget(name: "BeaconAgentAppleEventsTests", dependencies: ["BeaconAgentAppleEvents", "BeaconAgentCore"])
    ],
    swiftLanguageModes: [.v6]
)
