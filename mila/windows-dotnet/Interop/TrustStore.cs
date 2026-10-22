namespace Mila.Windows.Interop;

/// <summary>Loads the operator-approved trust document for a deployment.</summary>
internal static class MilaTrustStore
{
    private const int MaximumDocumentBytes = 8192;

    private static string PathName(string host) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Mila", "trust", host + ".json");

    /// <summary>
    /// Returns only an existing, bounded pinned document. Missing or malformed
    /// local state leaves the client signed out; it is never replaced silently.
    /// @cc [owner:ghuntley,label:security] mila-windows-trust-store-pinned
    /// The managed client MUST load only a bounded operator-pinned trust document;
    /// it MUST NOT accept a replacement document from the sign-in flow.
    /// Rust performs the authoritative document and certificate validation.
    /// </summary>
    internal static byte[]? Load(string host)
    {
        if (string.IsNullOrWhiteSpace(host) || host.Any(char.IsControl) || host.Contains('/') || host.Contains('\\'))
            return null;
        try
        {
            string path = PathName(host);
            FileInfo info = new(path);
            if (!info.Exists || info.Length is <= 0 or > MaximumDocumentBytes) return null;
            return File.ReadAllBytes(path);
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
}
