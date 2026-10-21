using System.Runtime.InteropServices;
using System.Text;

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
/// Status values returned by the Rust native library.
/// </summary>
internal enum MilaNativeStatus : int
{
    Ok = 0,
    NullInput = -1,
    InvalidRoute = -2,
    OutputTooSmall = -3,
    InvalidRequest = -4,
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

/// <summary>Caller-owned output buffer passed to the stable Rust route ABI.</summary>
[StructLayout(LayoutKind.Sequential)]
internal readonly struct MilaRouteOutput
{
    internal MilaRouteOutput(IntPtr bytes, nuint capacity, IntPtr written)
    {
        Bytes = bytes;
        Capacity = capacity;
        Written = written;
    }

    internal readonly IntPtr Bytes;
    internal readonly nuint Capacity;
    internal readonly IntPtr Written;
}

internal readonly record struct MilaNativeRouteResult(
    MilaNativeStatus Status,
    string? Canonical);

[StructLayout(LayoutKind.Sequential)]
internal readonly struct MilaSnapshotSummary
{
    internal readonly uint MachineCount;
    internal readonly ulong SavedAt;
}

internal readonly record struct MilaNativeSnapshotResult(
    MilaNativeStatus Status,
    MilaSnapshotSummary? Summary);

[Flags]
internal enum MilaMachineAction : ushort
{
    None = 0, Start = 1, Stop = 2, Pause = 4, Resume = 8,
    Pin = 16, Unpin = 32, Delete = 64,
}

[StructLayout(LayoutKind.Sequential)]
internal readonly struct MilaMachineActions
{
    internal readonly MilaMachineAction Bits;
}

internal readonly record struct MilaNativeActionsResult(
    MilaNativeStatus Status, MilaMachineAction? Actions);
internal readonly record struct MilaNativeCommandResult(
    MilaNativeStatus Status, string? Command);

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

    /// <summary>
    /// Canonicalizes a navigation route using the Rust closed route grammar.
    /// Managed callers never receive or provide raw pointers; this method owns
    /// temporary UTF-8 input and output storage for the duration of the call.
    /// </summary>
    internal static MilaNativeRouteResult TryFormatRoute(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.Contains('\0')) return new(MilaNativeStatus.InvalidRoute, null);
        byte[] inputBytes = Encoding.UTF8.GetBytes(value);
        IntPtr input = Marshal.AllocHGlobal(inputBytes.Length + 1);
        IntPtr bytes = Marshal.AllocHGlobal(RouteOutputCapacity);
        IntPtr written = Marshal.AllocHGlobal(nuint.Size);
        try
        {
            Marshal.Copy(inputBytes, 0, input, inputBytes.Length);
            Marshal.WriteByte(input, inputBytes.Length, 0);
            Marshal.WriteIntPtr(written, IntPtr.Zero);
            MilaRouteOutput output = new(bytes, (nuint)RouteOutputCapacity, written);
            MilaNativeStatus status = FormatRouteNative(input, output);
            if (status != MilaNativeStatus.Ok) return new(status, null);
            nuint length = (nuint)Marshal.ReadIntPtr(written);
            if (length > RouteOutputCapacity) return new(MilaNativeStatus.InvalidRoute, null);
            byte[] result = new byte[checked((int)length)];
            Marshal.Copy(bytes, result, 0, result.Length);
            return new(status, new UTF8Encoding(false, true).GetString(result));
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (DecoderFallbackException) { return new(MilaNativeStatus.InvalidRoute, null); }
        finally
        {
            Marshal.FreeHGlobal(input);
            Marshal.FreeHGlobal(bytes);
            Marshal.FreeHGlobal(written);
        }
    }

    /// <summary>Validates an offline snapshot against the active deployment.</summary>
    internal static MilaNativeSnapshotResult TryValidateSnapshot(
        ReadOnlySpan<byte> snapshot, string host, ushort port, bool hasPort)
    {
        ArgumentNullException.ThrowIfNull(host);
        if (host.Contains('\0')) return new(MilaNativeStatus.InvalidRequest, null);
        unsafe
        {
            fixed (byte* bytes = snapshot)
            {
                IntPtr hostPtr = Marshal.StringToCoTaskMemUTF8(host);
                try
                {
                    MilaNativeStatus status = ValidateSnapshotNative(
                        (IntPtr)bytes, (nuint)snapshot.Length, hostPtr, port,
                        hasPort ? (byte)1 : (byte)0, out MilaSnapshotSummary summary);
                    return status == MilaNativeStatus.Ok
                        ? new(status, summary)
                        : new(status, null);
                }
                catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
                catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
                catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
                finally { Marshal.FreeCoTaskMem(hostPtr); }
            }
        }
    }

    /// <summary>
    /// @cc [owner:ghuntley,label:security] mila-windows-rust-action-policy
    /// Available actions MUST come from Rust's deployment-validated snapshot;
    /// refusals MUST expose no actions and MUST NOT change local authority.
    /// </summary>
    internal static unsafe MilaNativeActionsResult TryGetMachineActions(
        ReadOnlySpan<byte> snapshot, string host, ushort? port, uint index)
    {
        ArgumentNullException.ThrowIfNull(host);
        if (host.Contains('\0')) return new(MilaNativeStatus.InvalidRequest, null);
        fixed (byte* bytes = snapshot)
        {
            IntPtr hostPtr = Marshal.StringToCoTaskMemUTF8(host);
            try
            {
                MilaNativeStatus status = MachineActionsNative((IntPtr)bytes,
                    (nuint)snapshot.Length, hostPtr, port ?? 0, port.HasValue ? (byte)1 : (byte)0,
                    index, out MilaMachineActions actions);
                return status == MilaNativeStatus.Ok ? new(status, actions.Bits) : new(status, null);
            }
            catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
            catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
            catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
            finally { Marshal.FreeCoTaskMem(hostPtr); }
        }
    }

    /// <summary>
    /// @cc [owner:ghuntley,label:protocol] mila-windows-command-format-only
    /// Commands MUST be formatted by Rust into bounded storage. Formatting MUST
    /// NOT submit a command or imply authentication, authorization or queuing.
    /// </summary>
    internal static MilaNativeCommandResult TryFormatMachineCommand(
        string action, Guid machineId, string? requestId)
    {
        ArgumentNullException.ThrowIfNull(action);
        if (action.Contains('\0') || requestId?.Contains('\0') == true)
            return new(MilaNativeStatus.InvalidRequest, null);
        IntPtr actionPtr = Marshal.StringToCoTaskMemUTF8(action);
        IntPtr machinePtr = Marshal.StringToCoTaskMemUTF8(machineId.ToString("D"));
        IntPtr requestPtr = requestId is null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(requestId);
        IntPtr bytes = Marshal.AllocHGlobal(RouteOutputCapacity);
        IntPtr written = Marshal.AllocHGlobal(nuint.Size);
        try
        {
            Marshal.WriteIntPtr(written, IntPtr.Zero);
            MilaNativeStatus status = MachineCommandNative(actionPtr, machinePtr, requestPtr,
                new(bytes, RouteOutputCapacity, written));
            if (status != MilaNativeStatus.Ok) return new(status, null);
            nuint length = (nuint)Marshal.ReadIntPtr(written);
            if (length > RouteOutputCapacity) return new(MilaNativeStatus.InvalidRequest, null);
            byte[] result = new byte[checked((int)length)];
            Marshal.Copy(bytes, result, 0, result.Length);
            return new(status, new UTF8Encoding(false, true).GetString(result));
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (DecoderFallbackException) { return new(MilaNativeStatus.InvalidRequest, null); }
        finally
        {
            Marshal.FreeCoTaskMem(actionPtr);
            Marshal.FreeCoTaskMem(machinePtr);
            Marshal.FreeCoTaskMem(requestPtr);
            Marshal.FreeHGlobal(bytes);
            Marshal.FreeHGlobal(written);
        }
    }

    [LibraryImport(LibraryName, EntryPoint = "mila_snapshot_machine_actions")]
    private static partial MilaNativeStatus MachineActionsNative(
        IntPtr bytes, nuint length, IntPtr host, ushort port, byte hasPort,
        uint index, out MilaMachineActions actions);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_command_format")]
    private static partial MilaNativeStatus MachineCommandNative(
        IntPtr action, IntPtr machineId, IntPtr requestId, MilaRouteOutput output);

    private const int RouteOutputCapacity = 4096;

    [LibraryImport(LibraryName, EntryPoint = "mila_ffi_get_version")]
    private static partial MilaNativeStatus GetVersionNative(
        out MilaNativeVersion version);

    [LibraryImport(LibraryName, EntryPoint = "mila_route_format")]
    private static partial MilaNativeStatus FormatRouteNative(
        IntPtr input,
        MilaRouteOutput output);

    [LibraryImport(LibraryName, EntryPoint = "mila_snapshot_validate")]
    private static partial MilaNativeStatus ValidateSnapshotNative(
        IntPtr bytes, nuint length, IntPtr host, ushort port, byte hasPort,
        out MilaSnapshotSummary summary);
}
