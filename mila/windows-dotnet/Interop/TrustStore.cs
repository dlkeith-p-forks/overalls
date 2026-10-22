namespace Mila.Windows.Interop;

internal delegate Task<byte[]> MilaTrustFetch(CancellationToken cancellationToken);
internal delegate MilaNativeTrustResult MilaTrustReconcile(byte[]? pinned, byte[]? fetched, string host, ulong now);

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
            using FileStream stream = File.OpenRead(path);
            return ReadBounded(stream);
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    internal static byte[]? ReadBounded(Stream stream)
    {
        byte[] buffer = new byte[MaximumDocumentBytes + 1];
        int length = stream.ReadAtLeast(buffer, buffer.Length, throwOnEndOfStream: false);
        return length is > 0 and <= MaximumDocumentBytes ? buffer[..length] : null;
    }

    /// <summary>Atomically persists Rust's canonical trust selection.</summary>
    internal static void Save(string host, ReadOnlySpan<byte> document)
    {
        if (string.IsNullOrWhiteSpace(host) || host.Any(char.IsControl) || host.Contains('/') || host.Contains('\\') ||
            document.Length is 0 or > MaximumDocumentBytes)
            throw new ArgumentException("invalid trust document", nameof(document));
        string path = PathName(host);
        string? directory = Path.GetDirectoryName(path);
        if (directory is null) throw new IOException("trust directory unavailable");
        Directory.CreateDirectory(directory);
        string temporary = path + ".new";
        try
        {
            using (FileStream stream = new(temporary, FileMode.Create, FileAccess.Write, FileShare.None,
                       4096, FileOptions.WriteThrough))
            {
                stream.Write(document);
                stream.Flush(true);
            }
            File.Move(temporary, path, true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}

/// <summary>Fetches, validates and persists one deployment's trust pin.</summary>
internal sealed class MilaTrustEnrollment
{
    private const int MaximumDocumentBytes = 8192;
    private readonly MilaTrustFetch fetch;
    private readonly MilaTrustReconcile reconcile;
    private readonly Func<ulong> clock;

    internal MilaTrustEnrollment(
        MilaTrustFetch fetch,
        MilaTrustReconcile? reconcile = null,
        Func<ulong>? clock = null)
    {
        this.fetch = fetch;
        this.reconcile = reconcile == null ? RustNative.TryReconcileTrust : reconcile;
        this.clock = clock ?? (() => (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    }

    internal async Task<byte[]?> ResolveAsync(string host, CancellationToken cancellationToken = default)
    {
        byte[]? pinned = MilaTrustStore.Load(host);
        byte[]? fetched;
        bool transportFailure = false;
        try
        {
            fetched = await fetch(cancellationToken);
        }
        catch (HttpRequestException)
        {
            transportFailure = true;
            fetched = null;
        }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            transportFailure = true;
            fetched = null;
        }
        if (!transportFailure && fetched is null) return null;
        MilaNativeTrustResult result = reconcile(pinned, fetched, host, clock());
        if (result.Document is null) return null;
        if (pinned is null || !pinned.AsSpan().SequenceEqual(result.Document))
            MilaTrustStore.Save(host, result.Document);
        return result.Document;
    }

    /// <summary>Creates a system-trust HTTPS fetcher with redirects disabled and an 8 KiB bound.</summary>
    internal static MilaTrustFetch HttpsFetch(string host)
    {
        return async cancellationToken =>
        {
            using HttpClientHandler handler = new() { AllowAutoRedirect = false };
            using HttpClient client = new(handler) { Timeout = TimeSpan.FromSeconds(15) };
            using HttpResponseMessage response = await client.GetAsync(
                $"https://{host}/bin/ssh-trust.json",
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength is > MaximumDocumentBytes)
                throw new InvalidDataException("trust document too large");
            await using Stream stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            byte[] bytes = new byte[MaximumDocumentBytes + 1];
            int size = 0;
            while (size < bytes.Length)
            {
                int count = await stream.ReadAsync(bytes.AsMemory(size), cancellationToken);
                if (count == 0) break;
                size += count;
            }
            if (size is 0 or > MaximumDocumentBytes) throw new InvalidDataException("invalid trust document size");
            return bytes[..size];
        };
    }
}
