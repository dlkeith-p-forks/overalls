using System.Text.Json;

namespace Mila.Windows.Interop;

internal sealed record MilaSettings(string Locale, bool DarkMode)
{
    internal static MilaSettings Defaults => new("en", false);
}

internal static class MilaSettingsStore
{
    private static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mila", "settings.json");
    internal static MilaSettings Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return MilaSettings.Defaults;
            MilaSettings? value = JsonSerializer.Deserialize<MilaSettings>(File.ReadAllText(FilePath));
            return value is { Locale.Length: >= 2 and <= 16 } ? value : MilaSettings.Defaults;
        }
        catch (IOException) { return MilaSettings.Defaults; }
        catch (JsonException) { return MilaSettings.Defaults; }
    }
    internal static void Save(MilaSettings settings)
    {
        if (settings.Locale.Length is < 2 or > 16 || settings.Locale.Any(char.IsWhiteSpace)) throw new ArgumentException("Invalid locale", nameof(settings));
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(settings));
    }
}
