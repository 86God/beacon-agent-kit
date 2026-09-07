// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalNotesAssistant",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LocalNotesAssistant", targets: ["LocalNotesAssistant"]),
        .executable(name: "local-notes-assistant", targets: ["LocalNotesAssistantCLI"])
    ],
    dependencies: [
        .package(name: "BeaconAgentKit", path: "../..")
    ],
    targets: [
        .target(
            name: "LocalNotesAssistant",
            dependencies: [
                .product(name: "BeaconAgentCore", package: "BeaconAgentKit"),
                .product(name: "BeaconAgentPersistence", package: "BeaconAgentKit"),
                .product(name: "BeaconAgentDevice", package: "BeaconAgentKit"),
                .product(name: "BeaconAgentMemory", package: "BeaconAgentKit")
            ]
        ),
        .executableTarget(
            name: "LocalNotesAssistantCLI",
            dependencies: ["LocalNotesAssistant"]
        ),
        .testTarget(
            name: "LocalNotesAssistantTests",
            dependencies: ["LocalNotesAssistant"]
        )
    ],
    swiftLanguageModes: [.v6]
)
