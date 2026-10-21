using System.Runtime.InteropServices;

namespace Mila.Windows.Interop;

internal static partial class RustNative
{
    // Exercise the production import with deliberately short caller-owned storage.
    internal static void CheckOutputBounds(string route)
    {
        IntPtr input = Marshal.StringToCoTaskMemUTF8(route);
        IntPtr buffer = Marshal.AllocHGlobal(3);
        IntPtr written = Marshal.AllocHGlobal(nuint.Size);
        try
        {
            for (int index = 0; index < 3; index++) Marshal.WriteByte(buffer, index, 0x5a);
            Marshal.WriteIntPtr(written, new IntPtr(123));
            MilaNativeStatus status = FormatRouteNative(input, new(buffer + 1, 1, written));
            Program.Require(status == MilaNativeStatus.OutputTooSmall, "short route output refusal");
            Program.Require(Marshal.ReadIntPtr(written) == new IntPtr(123), "short output preserves length");
            for (int index = 0; index < 3; index++)
                Program.Require(Marshal.ReadByte(buffer, index) == 0x5a, "short output preserves canaries");
        }
        finally
        {
            Marshal.FreeCoTaskMem(input);
            Marshal.FreeHGlobal(buffer);
            Marshal.FreeHGlobal(written);
        }
    }
}
