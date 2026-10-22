namespace Mila.Windows.Interop;

internal enum MilaSessionConnectionStateKind { SignedOut, Connecting, Ready, Failed }
internal sealed record MilaSessionConnectionState(MilaSessionConnectionStateKind Kind, ulong? Handle, MilaNativeStatus? Error);
internal delegate MilaNativeSessionConnectResult MilaConnect(ReadOnlySpan<byte> trust, string host,
    ReadOnlySpan<byte> publicKey, ushort port, uint timeoutMs, Func<byte[], byte[]> signer);

/// Owns the authenticated handle lifecycle shared by machine and thread controllers.
internal sealed class MilaSessionConnection : IDisposable
{
    private readonly object _gate = new();
    private readonly MilaConnect _connect;
    private readonly Action<ulong> _close;
    private long _generation;
    private bool _disposed;
    private MilaSessionConnectionState _state = new(MilaSessionConnectionStateKind.SignedOut, null, null);
    internal MilaSessionConnectionState State { get { lock (_gate) return _state; } }
    internal ulong? Handle => State.Handle;

    internal MilaSessionConnection() : this(RustNative.TrySessionConnect, handle => { RustNative.TrySessionClose(handle); }) { }
    internal MilaSessionConnection(MilaConnect connect, Action<ulong> close) { _connect = connect; _close = close; }

    /// <summary>
    /// @cc [owner:ghuntley,label:reliability] mila-windows-session-generation
    /// Sign-out or disposal MUST invalidate in-flight connections and close late handles.
    /// Native connection work MUST NOT hold the state lock or outlive signer custody.
    /// </summary>
    internal bool Connect(ReadOnlySpan<byte> trust, string host, ReadOnlySpan<byte> publicKey,
        ushort port, uint timeoutMs, Func<byte[], byte[]> signer)
    {
        long generation;
        ulong? previous;
        lock (_gate)
        {
            if (_disposed) return false;
            generation = ++_generation;
            previous = _state.Handle;
            _state = new(MilaSessionConnectionStateKind.Connecting, null, null);
        }
        if (previous is { } oldHandle) _close(oldHandle);
        MilaNativeSessionConnectResult result;
        try { result = _connect(trust, host, publicKey, port, timeoutMs, signer); }
        catch
        {
            lock (_gate)
                if (generation == _generation) _state = new(MilaSessionConnectionStateKind.Failed, null, MilaNativeStatus.Internal);
            throw;
        }
        lock (_gate)
        {
            if (generation == _generation && !_disposed)
            {
                _state = result.Succeeded
                    ? new(MilaSessionConnectionStateKind.Ready, result.Handle, null)
                    : new(MilaSessionConnectionStateKind.Failed, null, result.Status);
                return result.Succeeded;
            }
        }
        if (result.Handle is > 0) _close(result.Handle.Value);
        return false;
    }

    internal void SignOut() => Reset(false);
    private void Reset(bool dispose)
    {
        ulong? handle;
        lock (_gate)
        {
            _disposed |= dispose;
            ++_generation;
            handle = _state.Handle;
            _state = new(MilaSessionConnectionStateKind.SignedOut, null, null);
        }
        if (handle is { } value) _close(value);
    }
    public void Dispose() => Reset(true);
}
