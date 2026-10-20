import Flutter
import Foundation
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
      guard let host = HostName.valid(arguments["host"]) else { return result(Self.invalid("host")) }
      if let key = RunnerPokeKeychain.publicKey(host) {
        result(FlutterStandardTypedData(bytes: key))
      } else {
        result(Self.unavailable())
      }
    case "pokeKey.delete":
      guard let host = HostName.valid(arguments["host"]) else { return result(Self.invalid("host")) }
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
      guard let host = HostName.valid(arguments["host"]) else { return result(Self.invalid("host")) }
      if let point = DeviceKeys.publicPoint(host) {
        result(FlutterStandardTypedData(bytes: point))
      } else {
        result(Self.unavailable())
      }
    case "deviceKey.sign":
      guard let host = HostName.valid(arguments["host"]) else { return result(Self.invalid("host")) }
      guard let data = arguments["data"] as? FlutterStandardTypedData else { return result(Self.invalid("data")) }
      if let signature = DeviceKeys.sign(host, data.data) {
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

  private static func invalid(_ name: String) -> FlutterError {
    FlutterError(code: "invalid_argument", message: name, details: nil)
  }

  // Keychain failures carry no key material; report only that custody failed.
  private static func unavailable() -> FlutterError {
    FlutterError(code: "keystore_unavailable", message: nil, details: nil)
  }
}
