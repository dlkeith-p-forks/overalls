using System.Text.Json;

namespace Mila.Windows.Interop;

internal sealed record MilaSshKey(Guid Id, string Fingerprint, string Algorithm, string? Label, bool IsCurrentDevice);
internal enum MilaSshKeysStatus { SignedOut, Loading, Loaded, Failed }

internal sealed class MilaSshKeysController
{
    private readonly Func<CancellationToken, Task<IReadOnlyList<MilaSshKey>>> loader;
    private readonly Func<Guid, CancellationToken, Task> revoker;
    internal MilaSshKeysStatus Status { get; private set; } = MilaSshKeysStatus.SignedOut;
    internal IReadOnlyList<MilaSshKey> Keys { get; private set; } = Array.Empty<MilaSshKey>();

    internal MilaSshKeysController(Func<CancellationToken, Task<IReadOnlyList<MilaSshKey>>> loader, Func<Guid, CancellationToken, Task> revoker)
    { this.loader = loader; this.revoker = revoker; }

    internal async Task LoadAsync(bool signedIn, CancellationToken cancellationToken = default)
    {
        if (!signedIn) { Status = MilaSshKeysStatus.SignedOut; Keys = Array.Empty<MilaSshKey>(); return; }
        Status = MilaSshKeysStatus.Loading;
        try { Keys = await loader(cancellationToken); Status = MilaSshKeysStatus.Loaded; }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { Status = MilaSshKeysStatus.Loaded; }
        catch { Status = MilaSshKeysStatus.Failed; }
    }

    internal async Task RevokeAsync(MilaSshKey key, CancellationToken cancellationToken = default)
    {
        if (Status != MilaSshKeysStatus.Loaded || key.IsCurrentDevice) return;
        try { await revoker(key.Id, cancellationToken); await LoadAsync(true, cancellationToken); }
        catch { Status = MilaSshKeysStatus.Failed; }
    }

    internal static IReadOnlyList<MilaSshKey> DecodeListing(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > 256 * 1024) throw new InvalidDataException("SSH key listing too large");
        using JsonDocument document = JsonDocument.Parse(bytes);
        JsonElement keys = document.RootElement.GetProperty("keys");
        if (keys.ValueKind != JsonValueKind.Array || keys.GetArrayLength() > 256) throw new InvalidDataException("Invalid SSH key listing");
        List<MilaSshKey> result = new(keys.GetArrayLength());
        foreach (JsonElement item in keys.EnumerateArray())
        {
            if (!Guid.TryParse(item.GetProperty("id").GetString(), out Guid id)) throw new InvalidDataException("Invalid SSH key id");
            string fingerprint = item.GetProperty("fingerprint").GetString() ?? throw new InvalidDataException("Missing fingerprint");
            string algorithm = item.GetProperty("algorithm").GetString() ?? throw new InvalidDataException("Missing algorithm");
            string? label = item.TryGetProperty("label", out JsonElement labelElement) ? labelElement.GetString() : null;
            bool current = item.TryGetProperty("current_device", out JsonElement currentElement) && currentElement.GetBoolean();
            if (fingerprint.Length is 0 or > 256 || algorithm.Length is 0 or > 64 || label?.Length > 256) throw new InvalidDataException("Invalid SSH key field");
            result.Add(new(id, fingerprint, algorithm, label, current));
        }
        return result;
    }
}
