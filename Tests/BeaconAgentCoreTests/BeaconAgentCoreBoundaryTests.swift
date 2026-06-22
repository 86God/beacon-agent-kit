import XCTest

final class BeaconAgentCoreBoundaryTests: XCTestCase {
    func testBeaconAgentCoreDoesNotImportAppleUIOrDeviceFrameworks() throws {
        let sourceRoot = packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("BeaconAgentCore")
        let forbiddenImports = [
            "SwiftUI",
            "UIKit",
            "HealthKit",
            "ActivityKit",
            "WatchConnectivity",
            "CoreLocation",
            "UserNotifications"
        ]

        let swiftFiles = try swiftSourceFiles(in: sourceRoot)
        XCTAssertFalse(swiftFiles.isEmpty)

        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            for module in forbiddenImports {
                XCTAssertFalse(
                    source.contains("import \(module)"),
                    "\(file.lastPathComponent) must not import \(module); BeaconAgentCore stays Foundation-only."
                )
            }
        }
    }

    private func packageRoot(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftSourceFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }
}
