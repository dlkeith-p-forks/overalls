import CryptoKit
import Foundation
import Security

// Key custody shared by the iOS and macOS runners (ADR-0220, ADR-0235): one
// P-256 device key per deployment host in the Secure Enclave, and the X25519
// poke keys in the Keychain group shared with the NotificationService
// extension. Only public points and DER signatures leave these functions.
// macOS uses the data protection keychain, which the Secure Enclave and the
// shared access group both require there; iOS has no other keychain.

/// Hostname validation for channel arguments, as `mila_core`'s `isHostname`.
enum HostName {
  private static let pattern = try! NSRegularExpression(
    pattern: "^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")

  static func valid(_ value: Any?) -> String? {
    guard let host = value as? String else { return nil }
    let range = NSRange(host.startIndex..., in: host)
    return pattern.firstMatch(in: host, range: range) == nil ? nil : host
  }
}

/// Keychain attributes every Mila item carries on this platform.
enum MilaKeychain {
  static func scoped(_ query: [String: Any]) -> [String: Any] {
    #if os(macOS)
      var query = query
      query[kSecUseDataProtectionKeychain as String] = true
      return query
    #else
      return query
    #endif
  }
}

/// Secure Enclave P-256 device keys, one per deployment host.
enum DeviceKeys {
  private static func tag(_ host: String) -> Data { Data("dev.overalls.mila.device.\(host)".utf8) }

  private static func privateKey(_ host: String) -> SecKey? {
    let query = MilaKeychain.scoped([
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag(host),
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef as String: true,
    ])
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item {
      return (item as! SecKey)
    }
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil)
    else { return nil }
    let attributes = MilaKeychain.scoped([
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag(host),
        kSecAttrAccessControl as String: access,
      ],
    ])
    return SecKeyCreateRandomKey(attributes as CFDictionary, nil)
  }

  /// The uncompressed point `04 || X || Y`, 65 bytes.
  static func publicPoint(_ host: String) -> Data? {
    guard let key = privateKey(host), let publicKey = SecKeyCopyPublicKey(key),
      let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, data.count == 65
    else { return nil }
    return data
  }

  /// A DER ECDSA signature over SHA-256 of [data].
  static func sign(_ host: String, _ data: Data) -> Data? {
    guard let key = privateKey(host) else { return nil }
    return SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, data as CFData, nil) as Data?
  }
}

// @cc [owner:ghuntley,label:security] mila-poke-keys-stay-native
// Poke private keys MUST stay in the shared Keychain group, readable only
// after first unlock on this device. Only the 32-byte public key MAY cross the
// platform channel; private keys MUST NOT be logged or exported.

/// The runner's side of the poke key Keychain store: service
/// `dev.overalls.mila.poke`, account = deployment host, data = raw 32-byte
/// Curve25519 private key, in the access group shared with the
/// NotificationService extension (`PokeKeychain.swift` reads the same items).
enum RunnerPokeKeychain {
  static let service = "dev.overalls.mila.poke"

  /// `$(AppIdentifierPrefix)dev.overalls.mila.shared` from Info.plist.
  static var accessGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "MilaKeychainGroup") as? String
  }

  /// The shared group first; without the Keychain Sharing entitlement the
  /// group is refused (`errSecMissingEntitlement`), so the runner falls back
  /// to its default group and keeps working until the extension is wired in.
  private static func queries(_ host: String) -> [[String: Any]] {
    let plain = MilaKeychain.scoped([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: host,
    ])
    guard let group = accessGroup else { return [plain] }
    var shared = plain
    shared[kSecAttrAccessGroup as String] = group
    return [shared, plain]
  }

  static func privateKey(_ host: String) -> Data? {
    for base in queries(host) {
      var query = base
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecSuccess, let data = item as? Data, data.count == 32 { return data }
      if status != errSecMissingEntitlement && status != errSecItemNotFound { return nil }
    }
    return nil
  }

  static func store(_ host: String, _ key: Data) -> Bool {
    for base in queries(host) {
      var query = base
      query[kSecValueData as String] = key
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let status = SecItemAdd(query as CFDictionary, nil)
      if status == errSecSuccess { return true }
      if status != errSecMissingEntitlement { return false }
    }
    return false
  }

  static func delete(_ host: String) {
    for query in queries(host) { SecItemDelete(query as CFDictionary) }
  }

  /// The X25519 public key for [host], creating the key on first use.
  static func publicKey(_ host: String) -> Data? {
    if let stored = privateKey(host),
      let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored)
    {
      return key.publicKey.rawRepresentation
    }
    let key = Curve25519.KeyAgreement.PrivateKey()
    guard store(host, key.rawRepresentation) else { return nil }
    return key.publicKey.rawRepresentation
  }
}
