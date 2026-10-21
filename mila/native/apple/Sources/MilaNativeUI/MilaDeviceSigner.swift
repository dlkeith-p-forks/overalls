import CryptoKit
import Foundation
import Security

public enum MilaDeviceSignerError: Error {
    case invalidHost
    case keychain(OSStatus)
    case unavailable
    case invalidKey
    case invalidMessage
    case signingFailed
}

/// @cc [owner:ghuntley,label:security] native-apple-device-key-custody
/// Each deployment MUST use its own permanent Secure Enclave P-256 key; failed
/// lookup MUST NOT replace an existing key or fall back to software custody.
public final class MilaDeviceSigner {
    private let key: SecKey
    public let publicPoint: Data

    public init(deploymentHost: String) throws {
        guard Self.validHost(deploymentHost) else { throw MilaDeviceSignerError.invalidHost }
        let key = try Self.loadOrCreate(host: deploymentHost)
        guard let attributes = SecKeyCopyAttributes(key) as NSDictionary?,
              attributes[kSecAttrTokenID] as? String == kSecAttrTokenIDSecureEnclave as String,
              let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              point.count == 65, point.first == 4 else {
            throw MilaDeviceSignerError.invalidKey
        }
        _ = try P256.Signing.PublicKey(x963Representation: point)
        self.key = key
        self.publicPoint = point
    }

    public var openSSHPublicKey: String {
        var blob = Data()
        for field in [Data("ecdsa-sha2-nistp256".utf8), Data("nistp256".utf8), publicPoint] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { blob.append(contentsOf: $0) }
            blob.append(field)
        }
        return "ecdsa-sha2-nistp256 " + blob.base64EncodedString()
    }

    /// @cc [owner:ghuntley,label:security] native-apple-signature-format
    /// Sign raw nonempty messages of at most 64 KiB using SHA-256 exactly once.
    /// Return only the fixed-width 64-byte r||s signature, never private material.
    public func sign(message: Data) throws -> Data {
        guard !message.isEmpty, message.count <= 65_536 else {
            throw MilaDeviceSignerError.invalidMessage
        }
        guard let der = SecKeyCreateSignature(
            key, .ecdsaSignatureMessageX962SHA256, message as CFData, nil
        ) as Data? else { throw MilaDeviceSignerError.signingFailed }
        return try Self.rawSignature(der: der)
    }

    static func rawSignature(der: Data) throws -> Data {
        try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation
    }

    static func validHost(_ host: String) -> Bool {
        guard host.utf8.count <= 253, host.contains(".") else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    // Security.framework takes heterogeneous CFDictionary attributes; values here
    // are constructed locally. Returned key references are checked by CF type ID.
    private static func query(host: String) -> NSMutableDictionary {
        let query = NSMutableDictionary(dictionary: [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data("dev.overalls.mila.device.\(host)".utf8) as NSData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ])
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = NSNumber(value: true)
        #endif
        return query
    }

    private static func lookup(host: String) throws -> SecKey? {
        let query = query(host: host)
        query[kSecReturnRef as String] = NSNumber(value: true)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MilaDeviceSignerError.keychain(status) }
        guard let item, CFGetTypeID(item) == SecKeyGetTypeID() else {
            throw MilaDeviceSignerError.invalidKey
        }
        // CF runtime type has been checked above; Security exposes no conditional SecKey cast.
        return (item as! SecKey)
    }

    private static func loadOrCreate(host: String) throws -> SecKey {
        if let existing = try lookup(host: host) { return existing }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil
        ) else { throw MilaDeviceSignerError.unavailable }
        let attributes = query(host: host)
        attributes.removeObject(forKey: kSecClass as String)
        attributes.removeObject(forKey: kSecAttrApplicationTag as String)
        attributes[kSecAttrKeySizeInBits as String] = NSNumber(value: 256)
        attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        attributes[kSecPrivateKeyAttrs as String] = [
            kSecAttrIsPermanent as String: NSNumber(value: true),
            kSecAttrApplicationTag as String: Data("dev.overalls.mila.device.\(host)".utf8) as NSData,
            kSecAttrAccessControl as String: access,
        ] as NSDictionary
        if let created = SecKeyCreateRandomKey(attributes as CFDictionary, nil) { return created }
        // Another process may have created the same permanent item concurrently.
        if let existing = try lookup(host: host) { return existing }
        throw MilaDeviceSignerError.unavailable
    }
}
