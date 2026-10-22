namespace Mila.Windows.Interop;

internal enum MilaSessionConnectionStateKind { SignedOut, Connecting, Ready, Failed }
internal sealed record MilaSessionConnectionState(MilaSessionConnectionStateKind Kind, ulong? Handle, MilaNativeStatus? Error);

/// Owns the authenticated handle lifecycle shared by machine and thread controllers.
internal sealed class MilaSessionConnection : IDisposable
{
    internal MilaSessionConnectionState State { get; private set; } = new(MilaSessionConnectionStateKind.SignedOut, null, null);
    internal ulong? Handle => State.Handle;

    internal bool Connect(ReadOnlySpan<byte> trust, string host, ReadOnlySpan<byte> publicKey,
        ushort port, uint timeoutMs, Func<byte[], byte[]> signer)
    {
        State = new(MilaSessionConnectionStateKind.Connecting, null, null);
        MilaNativeSessionConnectResult result = RustNative.TrySessionConnect(trust, host, publicKey, port, timeoutMs, signer);
        State = result.Succeeded
            ? new(MilaSessionConnectionStateKind.Ready, result.Handle, null)
            : new(MilaSessionConnectionStateKind.Failed, null, result.Status);
        return result.Succeeded;
    }

    internal void SignOut()
    {
        if (Handle is { } handle) RustNative.TrySessionClose(handle);
        State = new(MilaSessionConnectionStateKind.SignedOut, null, null);
    }

    public void Dispose() => SignOut();
}
