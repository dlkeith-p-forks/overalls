import XCTest
@testable import MilaNativeUI

final class MilaRouteTests: XCTestCase {
    func testParsesSupportedRoutes() {
        let machineID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        XCTAssertEqual(MilaRouteParser.parse("overalls://overalls.example/machines"), .machines)
        XCTAssertEqual(MilaRouteParser.parse("overalls://overalls.example/machines/\(machineID.uuidString)"), .machine(id: machineID))
        XCTAssertEqual(MilaRouteParser.parse("overalls://overalls.example/threads"), .threads)
        XCTAssertEqual(MilaRouteParser.parse("overalls://overalls.example/threads/\(machineID.uuidString)"), .thread(id: machineID))
        XCTAssertEqual(MilaRouteParser.parse("overalls://overalls.example/settings"), .settings)
    }

    func testRejectsRoutesContainingSensitiveOrAmbiguousComponents() {
        let machineID = "11111111-1111-1111-1111-111111111111"
        let invalid = [
            "https://machines",
            "overalls://overalls.example/machines/\(machineID)?token=secret",
            "overalls://overalls.example/machines/\(machineID)#fragment",
            "overalls://overalls.example/machines/\(machineID)/terminal",
            "overalls://overalls.example/machines/not-a-uuid",
            "overalls://overalls.example/machines/%2F\(machineID)",
            "overalls://user@machines",
        ]
        for value in invalid {
            XCTAssertNil(MilaRouteParser.parse(value), "unexpectedly accepted \(value)")
        }
    }
}

final class MilaFFIRequestTests: XCTestCase {
    func testRequestsAreCodableAndPreservePayload() throws {
        let request = MilaFFIRequest(operation: .refresh, payload: Data([0, 1, 2, 255]))
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(MilaFFIRequest.self, from: encoded)
        XCTAssertEqual(decoded, request)
    }
}


final class MilaRustLinkTests: XCTestCase {
    func testLinkedRustCanonicalizesRoute() throws {
        let adapter = LinkedMilaFFIAdapter()
        XCTAssertEqual(try adapter.canonicalRoute("overalls://overalls.example/machines"), "overalls://overalls.example/machines")
    }
}
