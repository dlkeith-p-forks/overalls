import Foundation
import Security

// @cc [owner:ghuntley,label:security] mila-poke-keys-stay-native
// Poke private keys MUST stay in the shared Keychain group, readable only
// after first unlock on this device. Only the 32-byte public key MAY cross the
// platform channel; private keys MUST NOT be logged or exported.

/// The extension's reader of the poke keys the runner stores
/// (`MilaKeys.swift`'s `RunnerPokeKeychain` writes the same items) in the
/// shared Keychain group: service `dev.overalls.mila.poke`, account =
/// deployment host, data = raw 32-byte Curve25519 private key.
enum PokeKeychain {
  static let service = "dev.overalls.mila.poke"
  static let groupSuffix = "dev.overalls.mila.shared"

  /// `$(AppIdentifierPrefix)dev.overalls.mila.shared`, read from Info.plist
  /// (`MilaKeychainGroup`) so the team prefix is not hard-coded.
  static var accessGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "MilaKeychainGroup") as? String
  }

  private static func base(_ host: String?) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    if let host { query[kSecAttrAccount as String] = host }
    if let group = accessGroup { query[kSecAttrAccessGroup as String] = group }
    return MilaKeychain.scoped(query)
  }

  static func privateKey(_ host: String) -> Data? {
    var query = base(host)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
      data.count == 32
    else { return nil }
    return data
  }

  @discardableResult
  static func store(_ host: String, _ key: Data) -> Bool {
    var query = base(host)
    query[kSecValueData as String] = key
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
  }

  static func delete(_ host: String) {
    SecItemDelete(base(host) as CFDictionary)
  }

  /// Every stored (host, private key) pair.
  static func all() -> [(String, Data)] {
    var query = base(nil)
    query[kSecReturnAttributes as String] = true
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var items: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
      let rows = items as? [[String: Any]]
    else { return [] }
    return rows.compactMap { row in
      guard let host = row[kSecAttrAccount as String] as? String, let data = row[kSecValueData as String] as? Data,
        data.count == 32
      else { return nil }
      return (host, data)
    }
  }
}
