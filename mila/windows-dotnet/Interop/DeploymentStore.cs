using System.Text.Json;

namespace Mila.Windows.Interop;

internal sealed record MilaDeployment(string Host);

internal static class MilaDeploymentStore
{
    private static string PathName => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mila", "deployment.json");
    internal static MilaDeployment? Load()
    {
        try { return JsonSerializer.Deserialize<MilaDeployment>(File.ReadAllText(PathName)); }
        catch (IOException) { return null; }
        catch (JsonException) { return null; }
    }
    internal static void Save(MilaDeployment deployment)
    {
        string? directory = Path.GetDirectoryName(PathName);
        if (directory is null) return;
        Directory.CreateDirectory(directory);
        File.WriteAllText(PathName, JsonSerializer.Serialize(deployment));
    }
}
