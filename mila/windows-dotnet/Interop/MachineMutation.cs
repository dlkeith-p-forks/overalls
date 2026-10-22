namespace Mila.Windows.Interop;

internal enum MilaMachineMutationStateKind { SignedOut, Ready, Applied, Failed }
internal sealed record MilaMachineMutationState(MilaMachineMutationStateKind Kind, Guid? MachineId, string? Action, string? Error);

/// <summary>Owns authenticated machine mutation dispatch and keeps UI state typed.</summary>
internal sealed class MilaMachineMutationController
{
    internal MilaMachineMutationState State { get; private set; } = new(MilaMachineMutationStateKind.SignedOut, null, null, null);
    private bool _authenticated;
    private ulong _handle;

    internal void SetSession(bool authenticated, ulong handle = 0) {
        _authenticated = authenticated && handle != 0;
        _handle = _authenticated ? handle : 0;
        State = authenticated ? new(MilaMachineMutationStateKind.Ready, null, null, null) : new(MilaMachineMutationStateKind.SignedOut, null, null, null);
    }

    internal bool Submit(Guid machineId, string action, string requestId)
    {
        if (!_authenticated) { State = new(MilaMachineMutationStateKind.SignedOut, null, action, null); return false; }
        MilaNativeSessionActionResult result = RustNative.TrySessionMachineAction(_handle, machineId, action, requestId);
        State = result.Succeeded
            ? new(MilaMachineMutationStateKind.Applied, machineId, action, null)
            : new(MilaMachineMutationStateKind.Failed, machineId, action, result.Status.ToString());
        return result.Succeeded;
    }
}
