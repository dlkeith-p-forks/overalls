import Cocoa
import FlutterMacOS
import UserNotifications

/// The `dev.overalls.mila/platform` channel on macOS (ADR-0220, ADR-0235),
/// with the same methods as the iOS runner: Secure Enclave device keys and
/// Keychain poke keys (`darwin/Shared/MilaKeys.swift`), APNs tokens, the
/// sandbox container's data directory, `overalls://` links from Launch
/// Services, and HTTPS links to the default browser or the share picker.
/// Private keys never leave the enclave or the Keychain.
final class MilaPlatform: NSObject, UNUserNotificationCenterDelegate {
  static let channel = "dev.overalls.mila/platform"

  /// The live platform, for the app delegate's URL and APNs callbacks.
  private(set) static weak var shared: MilaPlatform?

  /// Links that arrived before the channel existed (a cold launch).
  private static var earlyLinks: [String] = []

  private let methods: FlutterMethodChannel
  private weak var view: NSView?
  /// The link the app was launched with, until Dart asks for it.
  private var initialLink: String?
  /// Whether Dart has asked for the launch link; later links are pushed.
  private var initialLinkTaken = false
  /// `push.token` calls waiting for APNs.
  private var pendingTokens: [FlutterResult] = []
  /// The last APNs token handed to Dart, to notice rotation. Never logged.
  private var lastToken: String?

  private init(_ methods: FlutterMethodChannel, view: NSView) {
    self.methods = methods
    self.view = view
  }

  static func register(with registrar: FlutterPluginRegistrar, view: NSView) {
    let platform = MilaPlatform(FlutterMethodChannel(name: channel, binaryMessenger: registrar.messenger), view: view)
    platform.methods.setMethodCallHandler { call, result in platform.handle(call, result) }
    shared = platform
    UNUserNotificationCenter.current().delegate = platform
    platform.initialLink = earlyLinks.first
    earlyLinks = []
  }

  // MARK: Links

  static func link(_ url: URL) -> String? {
    url.scheme == "overalls" && url.absoluteString.utf8.count <= 2048 ? url.absoluteString : nil
  }

  /// A link from Launch Services or a notification tap.
  static func open(_ link: String) {
    guard let shared else { return earlyLinks.append(link) }
    if shared.initialLinkTaken {
      shared.methods.invokeMethod("link", arguments: link)
    } else {
      // Until Dart asks, the newest link wins, as on iOS.
      shared.initialLink = link
    }
  }

  // MARK: Push

  func received(token: String) {
    let waiting = pendingTokens
    pendingTokens = []
    let changed = lastToken != nil && lastToken != token
    lastToken = token
    for result in waiting { result(token) }
    if waiting.isEmpty && changed { methods.invokeMethod("push.tokenChanged", arguments: token) }
  }

  func tokenFailed() {
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
        NSApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  /// A click on a decrypted notification opens its `overalls://` link.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let text = response.notification.request.content.userInfo["link"] as? String, let url = URL(string: text),
      let link = Self.link(url)
    {
      Self.open(link)
    }
    completionHandler()
  }

  // MARK: Channel

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
      // Development-signed builds use the APNs sandbox; Developer ID
      // releases production (`aps-environment` in the entitlements).
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
      // Inside the sandbox container: owner-only by construction.
      let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      result(url.path)
    case "openUrl":
      guard let url = Self.https(arguments["url"]) else { return result(Self.invalid("url")) }
      NSWorkspace.shared.open(url)
      result(nil)
    case "share":
      guard let url = Self.https(arguments["url"]) else { return result(Self.invalid("url")) }
      guard let view else { return result(Self.unavailable()) }
      NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func https(_ value: Any?) -> URL? {
    guard let text = value as? String, let url = URL(string: text), url.scheme == "https",
      HostName.valid(url.host) != nil
    else { return nil }
    return url
  }

  private static func invalid(_ name: String) -> FlutterError {
    FlutterError(code: "invalid_argument", message: name, details: nil)
  }

  // Keychain failures carry no key material; report only that custody failed.
  private static func unavailable() -> FlutterError {
    FlutterError(code: "keystore_unavailable", message: nil, details: nil)
  }
}
