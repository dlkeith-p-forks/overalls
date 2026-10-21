import Foundation

/// Stable message identities shared with the Rust localization catalog.
public enum MilaMessage: String, Sendable { case appName, machines, threads, settings, ready, refresh, connecting, connected, runtimeUnavailable, noAction }

public enum MilaStrings {
    public static func text(_ message: MilaMessage, locale: Locale = .current) -> String {
        // Native bundles can override these identities without changing UI code. English is deterministic fallback.
        switch message {
        case .appName: return "Mila"; case .machines: return "Machines"; case .threads: return "Threads"; case .settings: return "Settings"
        case .ready: return "Ready"; case .refresh: return "Refresh"; case .connecting: return "Connecting…"; case .connected: return "Connected"
        case .runtimeUnavailable: return "Native runtime unavailable"; case .noAction: return "No action selected"
        }
    }
}
