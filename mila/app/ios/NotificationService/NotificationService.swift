import UserNotifications

// @cc [owner:ghuntley,label:security;privacy] mila-native-notification-fixed-text
// A notification MUST carry only the fixed localized title and body and, for
// an authentic poke, the `overalls://` link of its route. It MUST NOT show or
// log poke bytes, plaintext, keys or tokens.

/// Decrypts a poke into a local notification (ADR-0224). The relay's alert
/// is replaced by fixed localized text; a decrypted route becomes the tap
/// link `overalls://HOST/ROUTE`. Nothing from the deployment is shown.
final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var fallback: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    let content = UNMutableNotificationContent()
    content.title = NSLocalizedString("MILA_NEEDS_INPUT_TITLE", comment: "")
    content.body = NSLocalizedString("MILA_NEEDS_INPUT_BODY", comment: "")
    content.sound = .default
    fallback = content
    if let poke = request.content.userInfo["poke"] as? String {
      for (host, key) in PokeKeychain.all() {
        if case .success(let opened) = PokeOpener.open(poke, host: host, privateKey: key) {
          content.userInfo = ["link": "overalls://\(host)\(opened.route)"]
          break
        }
      }
    }
    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    if let contentHandler, let fallback {
      fallback.userInfo = [:]
      contentHandler(fallback)
    }
  }
}
