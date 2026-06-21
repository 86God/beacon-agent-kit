import XCTest
@testable import BeaconAgentAppleEvents
@testable import BeaconAgentCore

final class BeaconAppleEventTests: XCTestCase {
    func testAppLifecycleEventRoundTrips() throws {
        let event = BeaconAppleEvent.appLifecycle(
            BeaconAppLifecycleEvent(kind: .enteredForeground, appSessionId: "session-1")
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BeaconAppleEvent.self, from: data)

        XCTAssertEqual(decoded.type, "app.enteredForeground")
        XCTAssertEqual(decoded.privacyLevel, .appState)
    }

    func testNotificationActionEventRoundTrips() throws {
        let event = BeaconAppleEvent.notification(
            BeaconNotificationEvent(kind: .actionTapped, notificationId: "notif-1", actionId: "open")
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BeaconAppleEvent.self, from: data)

        XCTAssertEqual(decoded.type, "notification.actionTapped")
        XCTAssertEqual(decoded.privacyLevel, .notificationContent)
    }

    func testApproximateLocationDoesNotRequirePreciseCoordinates() {
        let event = BeaconAppleEvent.location(
            BeaconLocationEvent(kind: .enteredRegion, regionId: "gym", approximateLabel: "near gym")
        )

        XCTAssertEqual(event.privacyLevel, .locationApproximate)
    }
}
