using System.Text.Json;

namespace Mila.Windows.Interop;

/// <summary>Bounded, typed projection of the Rust live-session listing.</summary>
internal sealed record MilaMachineRow(
    Guid Id,
    string Name,
    string DesiredState,
    string? ObservedState,
    bool Pinned,
    bool CanRead,
    bool CanWrite,
    bool CanManage);

internal sealed record MilaSessionListing(IReadOnlyList<MilaMachineRow> Machines, bool HasMore)
{
    internal const int MaxBytes = 8 * 1024 * 1024;
    internal const int MaxMachines = 10_000;

    internal static MilaSessionListing Decode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > MaxBytes) throw new InvalidDataException("listing exceeds bound");
        using JsonDocument document = JsonDocument.Parse(bytes);
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("machines", out JsonElement rows) ||
            rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > MaxMachines)
            throw new InvalidDataException("invalid machine listing");
        List<MilaMachineRow> machines = new(rows.GetArrayLength());
        foreach (JsonElement row in rows.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("id", out JsonElement idElement) ||
                idElement.ValueKind != JsonValueKind.String || !Guid.TryParseExact(idElement.GetString(), "D", out Guid id))
                throw new InvalidDataException("invalid machine id");
            string name = ReadString(row, "name") ?? id.ToString("D");
            string desired = ReadString(row, "desired_state") ?? "unknown";
            string? observed = ReadString(row, "observed_state");
            machines.Add(new(id, name, desired, observed,
                ReadBool(row, "pinned"), ReadBool(row, "read"), ReadBool(row, "write"), ReadBool(row, "manage")));
        }
        bool hasMore = root.TryGetProperty("has_more", out JsonElement more) && more.ValueKind == JsonValueKind.True;
        return new(machines, hasMore);
    }

    private static string? ReadString(JsonElement row, string name) =>
        row.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static bool ReadBool(JsonElement row, string name) =>
        row.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.True;
}
