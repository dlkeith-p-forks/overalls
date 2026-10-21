namespace Mila.Windows;

/// Stable message identities shared by all native clients. Platform resource bundles may
/// override these values; English is the deterministic fallback for an incomplete bundle.
internal static class MilaStrings
{
    internal static string AppName => "Mila";
    internal static string Machines => "Machines";
    internal static string Threads => "Threads";
    internal static string Settings => "Settings";
    internal static string Ready => "Ready";
    internal static string Connected => "Connected";
    internal static string RuntimeUnavailable => "Native runtime unavailable";
}
