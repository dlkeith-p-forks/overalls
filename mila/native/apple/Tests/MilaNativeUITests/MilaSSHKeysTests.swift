import XCTest
@testable import MilaNativeUI

@MainActor final class MilaSSHKeysTests: XCTestCase {
    func testLoadAndRevokeRefreshesOpaqueKeyIdentity() async {
        let id = UUID(); let key = MilaSSHKey(id: id, fingerprint: "SHA256:test", algorithm: "ssh-ed25519")
        var revoked: [UUID] = []; var loads = 0
        let controller = MilaSSHKeysController(loader: { loads += 1; return loads == 1 ? [key] : [] }, revoker: { revoked.append($0) })
        await controller.load(signedIn: true)
        XCTAssertEqual(controller.state, .loaded([key]))
        await controller.revoke(key)
        XCTAssertEqual(revoked, [id]); XCTAssertEqual(controller.state, .loaded([]))
    }

    func testSignedOutDoesNotLoadOrRevoke() async {
        var loaded = false
        let controller = MilaSSHKeysController(loader: { loaded = true; return [] }, revoker: { _ in XCTFail("must not revoke") })
        await controller.load(signedIn: false)
        XCTAssertEqual(controller.state, .signedOut); XCTAssertFalse(loaded)
    }
}
