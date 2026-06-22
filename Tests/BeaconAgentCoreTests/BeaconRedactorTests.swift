import XCTest
@testable import BeaconAgentCore

final class BeaconRedactorTests: XCTestCase {
    func testRedactsRawImageDataAndPhoneNumber() {
        let text = "phone 13800138000 image data:image/png;base64,abcdefghijk123456789 imageDataBase64=zyxwvutsrqponm123456"

        let redacted = BeaconRedactor.displayText(text)

        XCTAssertFalse(redacted.contains("13800138000"))
        XCTAssertFalse(redacted.contains("abcdefghijk"))
        XCTAssertFalse(redacted.contains("zyxwvuts"))
        XCTAssertTrue(redacted.contains("[phone redacted]"))
        XCTAssertTrue(redacted.contains("[image data redacted]"))
    }

    func testRedactsAPIKeys() {
        let text = "key sk-1234567890abcdef1234567890abcdef12345678"

        let redacted = BeaconRedactor.displayText(text)

        XCTAssertFalse(redacted.contains("sk-1234567890"))
        XCTAssertTrue(redacted.contains("[secret redacted]"))
    }
}
