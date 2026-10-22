namespace Mila.Windows.Interop;

/// <summary>Bounded, generation-fenced terminal lifecycle state.</summary>
internal sealed class MilaTerminalSession
{
    internal const int MaxOutputCharacters = 1_048_576;
    internal MilaTerminalState State { get; private set; } = MilaTerminalState.SignedOut;
    private long _generation;
    private bool _readWrite;
    private readonly System.Text.StringBuilder _output = new();

    internal string Output => _output.ToString();
    internal long BeginAttach(long generation, bool readWrite)
    {
        _generation = generation;
        _readWrite = readWrite;
        _output.Clear();
        State = readWrite ? MilaTerminalState.Attaching : MilaTerminalState.ReadOnly;
        return generation;
    }
    internal bool Append(long generation, ReadOnlySpan<char> text)
    {
        if (generation != _generation || State is MilaTerminalState.SignedOut or MilaTerminalState.Killed) return false;
        if (_output.Length + text.Length > MaxOutputCharacters) return false;
        _output.Append(text);
        State = MilaTerminalState.Live;
        return true;
    }
    internal bool Resize(long generation, ushort columns, ushort rows)
    {
        if (generation != _generation || !_readWrite || columns is 0 or > 4096 || rows is 0 or > 512) return false;
        State = MilaTerminalState.Live;
        return true;
    }
    internal bool SendInput(long generation, ReadOnlySpan<byte> input)
    {
        if (generation != _generation || !_readWrite || input.Length > MaxOutputCharacters || State is MilaTerminalState.SignedOut or MilaTerminalState.Killed) return false;
        return true;
    }
    internal bool Reconnect(long generation) => generation == _generation && State is (MilaTerminalState.Live or MilaTerminalState.ReadOnly);
    internal void Kill(long generation) { if (generation == _generation) State = MilaTerminalState.Killed; }
    internal void SignOut() { _generation++; _readWrite = false; State = MilaTerminalState.SignedOut; _output.Clear(); }
}

internal enum MilaTerminalState { SignedOut, Attaching, ReadOnly, Live, Killed }
