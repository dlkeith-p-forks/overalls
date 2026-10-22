import Foundation

/// Stable message identities shared with the Rust localization catalog.
public enum MilaMessage: String, Sendable { case appName, machines, threads, settings, ready, refresh, connecting, connected, runtimeUnavailable, noAction }

public enum MilaStrings {
    private static let ids: [MilaMessage: String] = [
        .appName: "appTitle", .machines: "machinesTitle", .threads: "tabThreads", .settings: "settingsTitle",
        .ready: "ready", .refresh: "refresh", .connecting: "signInConnecting", .connected: "connected",
        .runtimeUnavailable: "runtimeUnavailable", .noAction: "noAction"
    ]

    public static func text(_ message: MilaMessage, locale: Locale = .current) -> String {
        for candidate in [locale.identifier.replacingOccurrences(of: "_", with: "-"), locale.language.languageCode ?? "en", "en"] {
            if let value = resourceValue(message, locale: candidate) { return value }
        }
        switch message {
        case .appName: return "Mila"; case .machines: return "Machines"; case .threads: return "Threads"; case .settings: return "Settings"
        case .ready: return "Ready"; case .refresh: return "Refresh"; case .connecting: return "Connecting…"; case .connected: return "Connected"
        case .runtimeUnavailable: return "Native runtime unavailable"; case .noAction: return "No action selected"
        }
    }

    private static func resourceValue(_ message: MilaMessage, locale: String) -> String? {
        guard let url = Bundle.module.url(forResource: locale, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let domains = root["domains"] as? [String: Any],
              let mila = domains["mila"] as? [String: Any],
              let messages = mila["messages"] as? [[String: Any]] else { return nil }
        guard let entry = messages.first(where: { $0["id"] as? String == ids[message] }),
              let forms = entry["forms"] as? [String] else { return nil }
        return forms.first
    }
}
