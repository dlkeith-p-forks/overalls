using System.Runtime.InteropServices;

namespace Mila.Windows.Interop;

/// <summary>
/// Status values returned by the future Rust native library.
/// </summary>
internal enum MilaNativeStatus : int
{
    Ok = 0,
    InvalidArgument = 1,
    NativeFailure = 2,
    Unavailable = -1,
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

    [LibraryImport(LibraryName, EntryPoint = "mila_native_version")]
    private static partial MilaNativeStatus GetVersionNative(
        out MilaNativeVersion version);
}
