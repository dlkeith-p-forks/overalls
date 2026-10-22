import XCTest
@testable import MilaNativeUI

final class MilaDeepLinkRouterTests: XCTestCase {
    func testSignedOutLinksDoNotOpen() {
        var router = MilaDeepLinkRouter()
        XCTAssertEqual(router.decide("overalls://fleet.example/machines"), .signedOut(.machines))
    }

    func testGenerationFencesAuthenticatedLinks() {
        var router = MilaDeepLinkRouter()
        router.setSession(signedIn: true)
        let decision = router.decide("overalls://fleet.example/settings")
        guard case .open(_, let generation) = decision else { return XCTFail("expected open") }
        XCTAssertTrue(router.accepts(decision, generation: generation))
        router.setSession(signedIn: false)
        XCTAssertFalse(router.accepts(decision, generation: generation))
    }

    func testMalformedLinksAreUnknown() {
        var router = MilaDeepLinkRouter()
        router.setSession(signedIn: true)
        XCTAssertEqual(router.decide("overalls://fleet.example/settings?command=delete"), .unknown)
    }
}

