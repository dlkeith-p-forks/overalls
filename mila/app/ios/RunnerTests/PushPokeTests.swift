import CryptoKit
import XCTest

/// Shared vectors from `protocol/test/fixtures/push_pokes.json` (copied
/// inline: the test bundle has no access to the repository). The same vectors
/// test `OverallsProtocol.PushPoke`, `mila_core` and the Android opener.
final class PushPokeTests: XCTestCase {
  private struct Valid {
    let name, devicePrivate, devicePublic, host, poke, route: String
  }

  private struct Invalid {
    let name, devicePrivate, host, poke: String
    let reason: PokeOpener.Refusal
  }

  private static func hex(_ text: String) -> Data {
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(index, offsetBy: 2)
      data.append(UInt8(text[index..<next], radix: 16)!)
      index = next
    }
    return data
  }

  private static let valid: [Valid] = [
    Valid(
      name: "needs input 1",
      devicePrivate: "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
      devicePublic: "953562bec9901980512d93093a46a20df80045fcd8224e8f983ab09ac4665c43",
      host: "control.example.test",
      poke: "AWU0ylVBFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ulrAA_P2lfpER4-bytMbsWM4-DIkUWpFLLYHf6GHg-pIH6ZBx4FP9CPx3yeCBmXJYZeBcX5j4eN016siuvQsifIzA9_b4su9tYuq5XmaPNEvmgGQtT2G8k8LQ1KWHuc8b4Fs6Zmztg0YCpuL1MOBNn582M-P_-_BLDYOevdDIB-6UwXUORRg3u7r4UYGA",
      route: "/machines/2f0b8f8e-3c1d-4a8e-9b3e-0c6f1d2a7b11/threads/7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12"),
    Valid(
      name: "needs input 2",
      devicePrivate: "588605bf5362e8b7f170c8b2926c4061ab09a7d95c74c6ff9b45140b6787e0de",
      devicePublic: "db253adf1e64b6d3fed7ac50915bee644ba655009eb53ac81447e9f6e5a69c46",
      host: "control.example.test",
      poke: "AdgAhFkKTFO0D5_KI8HIKOMcYzdwTZZQvlclpFQhzZwKdHTB5-2SmvWA_mbkcyDe5n1tTWh8Oe1jmgoy0JG-ZFkCFBGmzdXTSemTvE8EnmwzOw36eJd_zYcR_xT5YutT9Tv6cfopxl18l3BcYP0ijixzhkzmwXUJxGHhxiqYuFXSQUFw1trC4oyN67rH6jXnTA",
      route: "/threads/7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12"),
  ]

  private static let invalid: [Invalid] = [
    Invalid(
      name: "tampered ciphertext",
      devicePrivate: "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
      host: "control.example.test",
      poke: "AWU0ylVBFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ukrAA_P2lfpER4-bytMbsWM4-DIkUWpFLLYHf6GHg-pIH6ZBx4FP9CPx3yeCBmXJYZeBcX5j4eN016siuvQsifIzA9_b4su9tYuq5XmaPNEvmgGQtT2G8k8LQ1KWHuc8b4Fs6Zmztg0YCpuL1MOBNn582M-P_-_BLDYOevdDIB-6UwXUORRg3u7r4UYGA",
      reason: .authentication),
    Invalid(
      name: "tampered ephemeral key",
      devicePrivate: "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
      host: "control.example.test",
      poke: "AWU0ylVAFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ulrAA_P2lfpER4-bytMbsWM4-DIkUWpFLLYHf6GHg-pIH6ZBx4FP9CPx3yeCBmXJYZeBcX5j4eN016siuvQsifIzA9_b4su9tYuq5XmaPNEvmgGQtT2G8k8LQ1KWHuc8b4Fs6Zmztg0YCpuL1MOBNn582M-P_-_BLDYOevdDIB-6UwXUORRg3u7r4UYGA",
      reason: .authentication),
    Invalid(
      name: "unknown version",
      devicePrivate: "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
      host: "control.example.test",
      poke: "AmU0ylVBFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ulrAA_P2lfpER4-bytMbsWM4-DIkUWpFLLYHf6GHg-pIH6ZBx4FP9CPx3yeCBmXJYZeBcX5j4eN016siuvQsifIzA9_b4su9tYuq5XmaPNEvmgGQtT2G8k8LQ1KWHuc8b4Fs6Zmztg0YCpuL1MOBNn582M-P_-_BLDYOevdDIB-6UwXUORRg3u7r4UYGA",
      reason: .version),
    Invalid(
      name: "truncated",
      devicePrivate: "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
      host: "control.example.test",
      poke: "AWU0ylVBFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ulrAA_P2lfpER4",
      reason: .length),
    Invalid(
      name: "other deployment",
      devicePrivate: "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
      host: "other.example.test",
      poke: "AWU0ylVBFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ulrAA_P2lfpER4-bytMbsWM4-DIkUWpFLLYHf6GHg-pIH6ZBx4FP9CPx3yeCBmXJYZeBcX5j4eN016siuvQsifIzA9_b4su9tYuq5XmaPNEvmgGQtT2G8k8LQ1KWHuc8b4Fs6Zmztg0YCpuL1MOBNn582M-P_-_BLDYOevdDIB-6UwXUORRg3u7r4UYGA",
      reason: .authentication),
  ]

  func testValidVectorsOpen() throws {
    for vector in Self.valid {
      let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.hex(vector.devicePrivate))
      XCTAssertEqual(key.publicKey.rawRepresentation, Self.hex(vector.devicePublic), vector.name)
      let opened = PokeOpener.open(vector.poke, host: vector.host, privateKey: Self.hex(vector.devicePrivate))
      XCTAssertEqual(opened, .success(PokeOpener.Poke(kind: "needs_input", route: vector.route)), vector.name)
    }
  }

  func testInvalidVectorsAreRefused() {
    for vector in Self.invalid {
      let opened = PokeOpener.open(vector.poke, host: vector.host, privateKey: Self.hex(vector.devicePrivate))
      XCTAssertEqual(opened, .failure(vector.reason), vector.name)
    }
  }

  func testNonCanonicalEncodingsAreRefused() {
    let vector = Self.valid[0]
    let key = Self.hex(vector.devicePrivate)
    XCTAssertEqual(PokeOpener.open(vector.poke + "=", host: vector.host, privateKey: key), .failure(.encoding))
    XCTAssertNil(PokeOpener.decodeBase64Url("AB"))
    XCTAssertEqual(PokeOpener.decodeBase64Url("AA"), Data([0]))
  }

  func testPlaintextSchemaIsExact() {
    XCTAssertNotNil(PokeOpener.decodePlaintext(Data(#"{"kind":"needs_input","route":"/threads","v":1}"#.utf8)))
    for json in [
      #"{"kind":"needs_input","route":"/threads"}"#,
      #"{"kind":"needs_input","route":"/threads","v":1.0}"#,
      #"{"kind":"needs_input","route":"/threads","v":true}"#,
      #"{"kind":"agent_done","route":"/threads","v":1}"#,
      #"{"kind":"needs_input","route":"https://evil.example/","v":1}"#,
      #"{"kind":"needs_input","route":"/threads","v":1,"title":"x"}"#,
    ] {
      XCTAssertNil(PokeOpener.decodePlaintext(Data(json.utf8)), json)
    }
  }
}
