using Mila.Windows.Interop;

internal static class SessionLifecycleSmoke
{
    internal static void Run()
    {
        foreach (bool dispose in new[] { false, true })
        {
            using ManualResetEventSlim entered = new(false);
            using ManualResetEventSlim release = new(false);
            int closed = 0;
            using MilaSessionConnection session = new(
                (ReadOnlySpan<byte> trust, string host, ReadOnlySpan<byte> key, ushort port, uint timeout, Func<byte[], byte[]> signer) =>
                {
                    entered.Set();
                    if (!release.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException();
                    return new(MilaNativeStatus.Ok, 42);
                }, handle => { Program.Require(handle == 42, "late handle identity"); Interlocked.Increment(ref closed); });
            Task<bool> connecting = Task.Run(() => session.Connect([], "example.test", [], 443, 1000, bytes => bytes));
            try
            {
                Program.Require(entered.Wait(TimeSpan.FromSeconds(10)), "connect started");
                if (dispose) session.Dispose(); else session.SignOut();
            }
            finally { release.Set(); }
            Program.Require(!connecting.GetAwaiter().GetResult(), "late connection rejected");
            Program.Require(session.Handle is null && closed == 1, "late handle closed exactly once");
        }
        foreach (int length in new[] { 0, 1, 8192, 8193, 16384 })
        {
            using MemoryStream input = new(new byte[length]);
            byte[]? result = MilaTrustStore.ReadBounded(input);
            Program.Require((result is not null) == (length is > 0 and <= 8192), "trust size bound");
            Program.Require(input.Position <= 8193, "trust read has fixed allocation limit");
        }
    }
}
