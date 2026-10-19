import CryptoKit
import Foundation

// @cc [owner:ghuntley,label:security;protocol] mila-native-poke-open-v1
// The native opener MUST refuse, without throwing, anything but an authentic
// v1 poke sealed to a stored device key for that key's deployment host, with
// exactly `{v: 1, kind: "needs_input", route}`. Refusals MUST NOT carry or log
// poke bytes, keys or plaintext.

/// Opens end-to-end encrypted pokes, format v1 (ADR-0224, ADR-0225), exactly
/// as `mila_core`'s `openPoke` and `protocol/test/fixtures/push_pokes.json`:
///
/// - `0x01 || ephemeral_public(32) || nonce(12) || ciphertext || tag(16)`,
///   base64url without padding;
/// - key = HKDF-SHA256(X25519(device, ephemeral), salt = ephemeral_public ||
///   device_public, info = "overalls-mila-poke-v1", 32 bytes);
/// - ChaCha20-Poly1305 with AAD "overalls-mila-poke-v1" || 0x00 || host;
/// - plaintext exactly {v: 1, kind: "needs_input", route: "/..."}.
///
/// Shared by the NotificationService extension and RunnerTests.
enum PokeOpener {
  static let label = "overalls-mila-poke-v1"
  static let minimumBytes = 1 + 32 + 12 + 16
  static let maximumPlaintext = 512
  static let maximumBytes = minimumBytes + maximumPlaintext

  enum Refusal: Error, Equatable { case encoding, length, version, authentication, plaintext }

  struct Poke: Equatable {
    let kind: String
    let route: String
  }

  private static let alphabet = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

  /// Strict unpadded base64url: no padding, no other alphabet, canonical only.
  static func decodeBase64Url(_ text: String) -> Data? {
    guard text.unicodeScalars.allSatisfy({ alphabet.contains($0) }), text.count % 4 != 1 else { return nil }
    var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while standard.count % 4 != 0 { standard += "=" }
    guard let data = Data(base64Encoded: standard), encodeBase64Url(data) == text else { return nil }
    return data
  }

  static func encodeBase64Url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func associatedData(_ host: String) -> Data {
    var aad = Data(label.utf8)
    aad.append(0)
    aad.append(Data(host.utf8))
    return aad
  }

  static func open(_ poke: String, host: String, privateKey: Data) -> Result<Poke, Refusal> {
    guard poke.utf8.count <= (maximumBytes * 4 + 2) / 3 else { return .failure(.length) }
    guard let bytes = decodeBase64Url(poke) else { return .failure(.encoding) }
    guard bytes.count >= minimumBytes, bytes.count <= maximumBytes else { return .failure(.length) }
    let b = [UInt8](bytes)
    guard b[0] == 1 else { return .failure(.version) }
    guard host.allSatisfy({ $0.isASCII }), !host.isEmpty else { return .failure(.authentication) }
    let ephemeralBytes = Data(b[1..<33])
    let combined = Data(b[33...])  // nonce || ciphertext || tag
    do {
      let device = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
      let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralBytes)
      let shared = try device.sharedSecretFromKeyAgreement(with: ephemeral)
      // An all-zero (low-order) result is never authentic.
      let zero = shared.withUnsafeBytes { raw in raw.allSatisfy { $0 == 0 } }
      if zero { return .failure(.authentication) }
      var salt = ephemeralBytes
      salt.append(device.publicKey.rawRepresentation)
      let key = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: salt, sharedInfo: Data(label.utf8), outputByteCount: 32)
      let box = try ChaChaPoly.SealedBox(combined: combined)
      let plaintext = try ChaChaPoly.open(box, using: key, authenticating: associatedData(host))
      guard let decoded = decodePlaintext(plaintext) else { return .failure(.plaintext) }
      return .success(decoded)
    } catch {
      return .failure(.authentication)
    }
  }

  static func decodePlaintext(_ plaintext: Data) -> Poke? {
    guard plaintext.count <= maximumPlaintext,
      let object = try? JSONSerialization.jsonObject(with: plaintext),
      let value = object as? [String: Any], value.count == 3,
      let version = value["v"] as? NSNumber,
      CFGetTypeID(version) == CFNumberGetTypeID(), !CFNumberIsFloatType(version), version.intValue == 1,
      let kind = value["kind"] as? String, kind == "needs_input",
      let route = value["route"] as? String, validRoute(route)
    else { return nil }
    return Poke(kind: kind, route: route)
  }

  /// A coarse shape check; the Dart router re-validates the closed table.
  static func validRoute(_ route: String) -> Bool {
    guard route.hasPrefix("/"), route.utf8.count <= 256 else { return false }
    return route.unicodeScalars.allSatisfy { s in
      (s >= "a" && s <= "z") || (s >= "0" && s <= "9") || s == "/" || s == "-"
    }
  }
}
