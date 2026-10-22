import XCTest
@testable import MilaNativeUI

final class MilaWebControlsTests: XCTestCase {
    @MainActor func testHTTPSOnlyAndCredentialFreeEndpoint() {
        let controller = MilaWebControlsController()
        XCTAssertTrue(controller.set("https://console.example.test/control"))
        XCTAssertNotNil(controller.endpoint)
        XCTAssertFalse(controller.set("http://console.example.test"))
        XCTAssertNil(controller.endpoint)
        XCTAssertFalse(controller.set("https://user:secret@console.example.test"))
        XCTAssertFalse(controller.set("https://console.example.test/#fragment"))
    }
}
