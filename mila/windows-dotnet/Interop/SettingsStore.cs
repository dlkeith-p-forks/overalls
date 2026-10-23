using System.Text.Json;
using System.Text.RegularExpressions;

namespace Mila.Windows.Interop;

internal sealed record MilaSettings(string Locale, bool DarkMode)
{
    internal static MilaSettings Defaults => new("en", false);

    internal static bool IsValidLocale(string locale)
    {
        string normalized = locale.Trim().Replace('_', '-');
        return normalized.Length is >= 2 and <= 35 && Regex.IsMatch(normalized, "^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$", RegexOptions.CultureInvariant);
    }

    internal MilaSettings Normalize() => this with { Locale = Locale.Trim().Replace('_', '-') };
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
            return value is not null && MilaSettings.IsValidLocale(value.Locale) ? value.Normalize() : MilaSettings.Defaults;
        }
        catch (IOException) { return MilaSettings.Defaults; }
        catch (JsonException) { return MilaSettings.Defaults; }
    }
    internal static void Save(MilaSettings settings)
    {
        MilaSettings normalized = settings.Normalize();
        if (!MilaSettings.IsValidLocale(normalized.Locale)) throw new ArgumentException("Invalid locale", nameof(settings));
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(normalized));
    }
}
