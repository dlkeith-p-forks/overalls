import CryptoKit
import Flutter
import Foundation
import Security
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    MilaPlatform.shared?.received(token: deviceToken.map { String(format: "%02x", $0) }.joined())
  }

  override func application(
    _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    MilaPlatform.shared?.tokenFailed()
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MilaPlatform") {
      MilaPlatform.register(with: registrar)
    }
  }
}


/// The `dev.overalls.mila/platform` channel (ADR-0220): one P-256 device key
/// per deployment host in the Secure Enclave, and `overalls://` links from
/// the scene. Private keys never leave the enclave; only the public point and
/// DER signatures cross the channel. Flutter deep linking is disabled in
/// Info.plist, so links reach Mila only through this channel.
final class MilaPlatform: NSObject, FlutterSceneLifeCycleDelegate, UNUserNotificationCenterDelegate {
  static let channel = "dev.overalls.mila/platform"

  /// The live platform, for the app delegate's APNs callbacks.
  fileprivate(set) static weak var shared: MilaPlatform?

  private let methods: FlutterMethodChannel
  /// The link the app was launched with, until Dart asks for it.
  private var initialLink: String?
  /// Whether Dart has asked for the launch link; later links are pushed.
  private var initialLinkTaken = false
  /// `push.token` calls waiting for APNs.
  private var pendingTokens: [FlutterResult] = []
  /// The last APNs token handed to Dart, to notice rotation. Never logged.
  private var lastToken: String?

  private init(_ methods: FlutterMethodChannel) { self.methods = methods }

  private static let host = try! NSRegularExpression(
    pattern: "^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")

  static func register(with registrar: FlutterPluginRegistrar) {
    let platform = MilaPlatform(FlutterMethodChannel(name: channel, binaryMessenger: registrar.messenger()))
    platform.methods.setMethodCallHandler { call, result in platform.handle(call, result) }
    registrar.addSceneDelegate(platform)
    shared = platform
    UNUserNotificationCenter.current().delegate = platform
  }

  // MARK: Push

  fileprivate func received(token: String) {
    let waiting = pendingTokens
    pendingTokens = []
    let changed = lastToken != nil && lastToken != token
    lastToken = token
    for result in waiting { result(token) }
    if waiting.isEmpty && changed { methods.invokeMethod("push.tokenChanged", arguments: token) }
  }

  fileprivate func tokenFailed() {
    let waiting = pendingTokens
    pendingTokens = []
    for result in waiting { result(FlutterError(code: "push_unavailable", message: nil, details: nil)) }
  }

  private func requestToken(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      DispatchQueue.main.async {
        guard granted else {
          return result(FlutterError(code: "permission_denied", message: nil, details: nil))
        }
        self.pendingTokens.append(result)
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  /// A tap on a decrypted notification opens its `overalls://` link.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let text = response.notification.request.content.userInfo["link"] as? String, let url = URL(string: text),
      let link = Self.link(url)
    {
      if initialLinkTaken {
        methods.invokeMethod("link", arguments: link)
      } else {
        initialLink = link
      }
    }
    completionHandler()
  }

  // MARK: Poke keys

  /// The X25519 public key for [host], creating the key on first use. The
  /// private key stays in the shared Keychain group for the extension.
  private static func pokePublicKey(_ host: String) -> Data? {
    if let stored = RunnerPokeKeychain.privateKey(host),
      let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored)
    {
      return key.publicKey.rawRepresentation
    }
    let key = Curve25519.KeyAgreement.PrivateKey()
    guard RunnerPokeKeychain.store(host, key.rawRepresentation) else { return nil }
    return key.publicKey.rawRepresentation
  }

  private static func link(_ url: URL) -> String? { url.scheme == "overalls" ? url.absoluteString : nil }

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    if let url = connectionOptions?.urlContexts.first?.url, let link = Self.link(url) { initialLink = link }
    return false
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    let links = URLContexts.compactMap { Self.link($0.url) }
    for link in links { methods.invokeMethod("link", arguments: link) }
    return !links.isEmpty
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "link.initial":
      result(initialLink)
      initialLink = nil
      initialLinkTaken = true
    case "pokeKey.public":
      guard let host = Self.validHost(arguments["host"]) else { return result(Self.invalid("host")) }
      if let key = Self.pokePublicKey(host) {
        result(FlutterStandardTypedData(bytes: key))
      } else {
        result(Self.unavailable())
      }
    case "pokeKey.delete":
      guard let host = Self.validHost(arguments["host"]) else { return result(Self.invalid("host")) }
      RunnerPokeKeychain.delete(host)
      result(nil)
    case "push.token":
      requestToken(result)
    case "push.environment":
      // Debug builds are signed for the APNs sandbox; distribution builds
      // (TestFlight, App Store) for production.
      #if DEBUG
        result("development")
      #else
        result("production")
      #endif
    case "deviceKey.public":
      guard let host = Self.validHost(arguments["host"]) else { return result(Self.invalid("host")) }
      if let point = Self.publicPoint(host) {
        result(FlutterStandardTypedData(bytes: point))
      } else {
        result(Self.unavailable())
      }
    case "deviceKey.sign":
      guard let host = Self.validHost(arguments["host"]) else { return result(Self.invalid("host")) }
      guard let data = arguments["data"] as? FlutterStandardTypedData else { return result(Self.invalid("data")) }
      if let signature = Self.sign(host, data.data) {
        result(FlutterStandardTypedData(bytes: signature))
      } else {
        result(Self.unavailable())
      }
    case "dataDirectory":
      let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      result(url.path)
    case "openUrl":
      guard let text = arguments["url"] as? String, let url = URL(string: text), url.scheme == "https" else {
        return result(Self.invalid("url"))
      }
      UIApplication.shared.open(url)
      result(nil)
    case "share":
      // A web endpoint link to the system share sheet; HTTPS only.
      guard let text = arguments["url"] as? String, let url = URL(string: text), url.scheme == "https" else {
        return result(Self.invalid("url"))
      }
      let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      let root = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
        .first
      sheet.popoverPresentationController?.sourceView = root?.view
      root?.present(sheet, animated: true)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func validHost(_ value: Any?) -> String? {
    guard let host = value as? String else { return nil }
    let range = NSRange(host.startIndex..., in: host)
    return Self.host.firstMatch(in: host, range: range) == nil ? nil : host
  }

  private static func invalid(_ name: String) -> FlutterError {
    FlutterError(code: "invalid_argument", message: name, details: nil)
  }

  // Keychain failures carry no key material; report only that custody failed.
  private static func unavailable() -> FlutterError {
    FlutterError(code: "keystore_unavailable", message: nil, details: nil)
  }

  private static func tag(_ host: String) -> Data { Data("dev.overalls.mila.device.\(host)".utf8) }

  private static func privateKey(_ host: String) -> SecKey? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag(host),
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef as String: true,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item {
      return (item as! SecKey)
    }
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil)
    else { return nil }
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag(host),
        kSecAttrAccessControl as String: access,
      ],
    ]
    return SecKeyCreateRandomKey(attributes as CFDictionary, nil)
  }

  /// The uncompressed point `04 || X || Y`, 65 bytes.
  private static func publicPoint(_ host: String) -> Data? {
    guard let key = privateKey(host), let publicKey = SecKeyCopyPublicKey(key),
      let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, data.count == 65
    else { return nil }
    return data
  }

  /// A DER ECDSA signature over SHA-256 of [data].
  private static func sign(_ host: String, _ data: Data) -> Data? {
    guard let key = privateKey(host) else { return nil }
    return SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, data as CFData, nil) as Data?
  }
}

// @cc [owner:ghuntley,label:security] mila-poke-keys-stay-native
// Poke private keys MUST stay in the shared Keychain group, readable only
// after first unlock on this device. Only the 32-byte public key MAY cross the
// platform channel; private keys MUST NOT be logged or exported.

/// Runner's side of the poke key Keychain store: service
/// `dev.overalls.mila.poke`, account = deployment host, data = raw 32-byte
/// Curve25519 private key, in the access group shared with the
/// NotificationService extension (`NotificationService/PokeKeychain.swift`
/// reads the same items). Kept here so the Runner target builds without
/// project changes.
private enum RunnerPokeKeychain {
  static let service = "dev.overalls.mila.poke"

  /// `$(AppIdentifierPrefix)dev.overalls.mila.shared` from Info.plist.
  static var accessGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "MilaKeychainGroup") as? String
  }

  /// The shared group first; without the Keychain Sharing entitlement the
  /// group is refused (`errSecMissingEntitlement`), so Runner falls back to
  /// its default group and keeps working until the extension is wired in.
  private static func queries(_ host: String) -> [[String: Any]] {
    let plain: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: host,
    ]
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
}
