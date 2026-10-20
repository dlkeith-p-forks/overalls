import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// `overalls://` links from Launch Services (CFBundleURLTypes). macOS keeps
  /// one instance, so later links reach the running app here too.
  override func application(_ application: NSApplication, open urls: [URL]) {
    for link in urls.compactMap(MilaPlatform.link) { MilaPlatform.open(link) }
  }

  override func application(
    _ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    MilaPlatform.shared?.received(token: deviceToken.map { String(format: "%02x", $0) }.joined())
  }

  override func application(
    _ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    MilaPlatform.shared?.tokenFailed()
  }
}
