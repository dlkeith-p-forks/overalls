import Flutter
import Foundation
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
final class MilaPlatform: NSObject, FlutterSceneLifeCycleDelegate {
  static let channel = "dev.overalls.mila/platform"

  private let methods: FlutterMethodChannel
  /// The link the app was launched with, until Dart asks for it.
  private var initialLink: String?

  private init(_ methods: FlutterMethodChannel) { self.methods = methods }

  private static let host = try! NSRegularExpression(
    pattern: "^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")

  static func register(with registrar: FlutterPluginRegistrar) {
    let platform = MilaPlatform(FlutterMethodChannel(name: channel, binaryMessenger: registrar.messenger()))
    platform.methods.setMethodCallHandler { call, result in platform.handle(call, result) }
    registrar.addSceneDelegate(platform)
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
