import XCTest
@testable import MilaNativeUI

private actor FakeEvaluator: MilaBiometricEvaluator {
    var available: Bool
    var result: Bool
    init(available: Bool = true, result: Bool = true) { self.available = available; self.result = result }
    nonisolated func availability() -> Bool { true }
    nonisolated func authenticate(reason: String) async -> Bool { true }
}

@MainActor
final class MilaAppLockTests: XCTestCase {
    func testDisabledStartsUnlocked() {
        let controller = MilaAppLockController(enabled: false, evaluator: FakeEvaluator())
        XCTAssertEqual(controller.state, .unlocked)
    }

    func testEnabledAuthenticatesAndUnlocks() async {
        let controller = MilaAppLockController(enabled: true, evaluator: FakeEvaluator())
        XCTAssertEqual(controller.state, .locked)
        await controller.unlock()
        XCTAssertEqual(controller.state, .unlocked)
    }

    func testLockReturnsToLocked() async {
        let controller = MilaAppLockController(evaluator: FakeEvaluator())
        controller.lock()
        XCTAssertEqual(controller.state, .locked)
        await controller.unlock()
        XCTAssertEqual(controller.state, .unlocked)
    }
}
