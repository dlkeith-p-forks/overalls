using System.Runtime.InteropServices;

namespace Mila.Windows.Interop;

internal enum MilaRouteKind { Machines, Machine, Threads, Thread, Settings }
internal readonly record struct MilaRoute(MilaRouteKind Kind, Guid? Id = null);

internal static class MilaRouteParser
{
    internal static MilaRoute? Parse(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out Uri? uri) ||
            uri.Scheme != "overalls" || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment) ||
            !string.IsNullOrEmpty(uri.UserInfo)) return null;
        string[] parts = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return uri.Host.ToLowerInvariant() switch
        {
            "machines" => new(MilaRouteKind.Machines),
            "threads" => new(MilaRouteKind.Threads),
            "settings" => new(MilaRouteKind.Settings),
            _ => null,
        };
        if (parts.Length != 1 || !Guid.TryParseExact(parts[0], "D", out Guid id)) return null;
        return uri.Host.ToLowerInvariant() switch
        {
            "machines" => new(MilaRouteKind.Machine, id),
            "threads" => new(MilaRouteKind.Thread, id),
            _ => null,
        };
    }
}

/// <summary>
/// Status values returned by the future Rust native library.
/// </summary>
internal enum MilaNativeStatus : int
{
    Ok = 0,
    NullInput = -1,
    InvalidRoute = -2,
    OutputTooSmall = -3,
    Unavailable = -127,
}

/// <summary>
/// Version returned by the native ABI. Keep this layout in sync with Rust's
/// <c>#[repr(C)]</c> struct when the implementation is added.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal readonly struct MilaNativeVersion
{
    internal MilaNativeVersion(uint major, uint minor)
    {
        Major = major;
        Minor = minor;
    }

    internal readonly uint Major;

    internal readonly uint Minor;
}

/// <summary>Typed result from the native version probe.</summary>
internal readonly record struct MilaNativeVersionResult(
    MilaNativeStatus Status,
    MilaNativeVersion? Version);

/// <summary>
/// Narrow P/Invoke boundary for the Rust implementation.
///
/// The DLL is intentionally absent from this scaffold. Callers receive
/// <see cref="MilaNativeStatus.Unavailable"/> until the Windows build stages
/// the Rust library produced by the source bundle.
/// </summary>
internal static partial class RustNative
{
    private const string LibraryName = "mila_native";

    /// <summary>
    /// Queries the native ABI version without exposing raw pointers to callers.
    /// </summary>
    /// <returns>A typed status and an optional version.</returns>
    internal static MilaNativeVersionResult TryGetVersion()
    {
        try
        {
            MilaNativeStatus status = GetVersionNative(out MilaNativeVersion version);
            return status == MilaNativeStatus.Ok
                ? new(status, version)
                : new(status, null);
        }
        catch (DllNotFoundException)
        {
            return new(MilaNativeStatus.Unavailable, null);
        }
        catch (EntryPointNotFoundException)
        {
            return new(MilaNativeStatus.Unavailable, null);
        }
        catch (BadImageFormatException)
        {
            return new(MilaNativeStatus.Unavailable, null);
        }
    }

    [LibraryImport(LibraryName, EntryPoint = "mila_ffi_get_version")]
    private static partial MilaNativeStatus GetVersionNative(
        out MilaNativeVersion version);
}
