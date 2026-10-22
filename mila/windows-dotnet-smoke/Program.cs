using System.Text;
using Mila.Windows.Interop;

/// <summary>
/// @cc [owner:ghuntley,label:verification] mila-windows-smoke-real-abi
/// The smoke executable MUST fail unless the production interop invokes the staged
/// Rust library successfully; Unavailable MUST NOT count as passing evidence.
/// </summary>
internal static class Program
{
    internal static void Require(bool condition, string check)
    {
        if (!condition) throw new InvalidOperationException(check);
    }

    private static void Main()
    {
        MilaNativeVersionResult version = RustNative.TryGetVersion();
        Require(version.Status == MilaNativeStatus.Ok && version.Version is { Major: 1, Minor: 0 }, "ABI version 1.0");
        const string route = "overalls://mgmt.example.test:8443/machines/0d9cc041-9db2-4e4c-b28b-1e41d7f472c1";
        MilaNativeRouteResult formatted = RustNative.TryFormatRoute(route);
        Require(formatted.Status == MilaNativeStatus.Ok && formatted.Canonical == route, "host-qualified canonical route");
        MilaNativeRouteResult invalid = RustNative.TryFormatRoute("overalls://mgmt.example.test/unknown");
        Require(invalid.Status == MilaNativeStatus.InvalidRoute && invalid.Canonical is null, "invalid route refusal");
        byte[] snapshot = Encoding.UTF8.GetBytes("""
            {"version":1,"host":"mgmt.example.test","port":8443,"saved_at":4294967298,"machines":[]}
            """);
        MilaNativeSnapshotResult valid = RustNative.TryValidateSnapshot(snapshot, "mgmt.example.test", 8443, true);
        Require(valid.Status == MilaNativeStatus.Ok && valid.Summary is { MachineCount: 0, SavedAt: 4294967298 }, "snapshot summary layout");
        RefusesSnapshot(snapshot, "foreign.example.test", 8443);
        RefusesSnapshot(snapshot, "mgmt.example.test", 443);
        RefusesSnapshot("{"u8.ToArray(), "mgmt.example.test", 8443);
        byte[] oversized = new byte[(1 << 20) + 1];
        Array.Fill(oversized, (byte)' ');
        snapshot.CopyTo(oversized, 0);
        RefusesSnapshot(oversized, "mgmt.example.test", 8443);
        byte[] machineSnapshot = Encoding.UTF8.GetBytes("""
            {"version":1,"host":"mgmt.example.test","port":8443,"saved_at":1,"machines":[{"id":"0d9cc041-9db2-4e4c-b28b-1e41d7f472c1","name":"test","desired_state":"running","observed_state":"running","pinned":false,"owner":"test","read":true,"write":true,"manage":true}]}
            """);
        MilaNativeActionsResult actions = RustNative.TryGetMachineActions(machineSnapshot, "mgmt.example.test", 8443, 0);
        Require(actions.Status == MilaNativeStatus.Ok && actions.Actions ==
            (MilaMachineAction.Stop | MilaMachineAction.Pause | MilaMachineAction.Pin | MilaMachineAction.Delete), "Rust action projection");
        Require(RustNative.TryGetMachineActions(machineSnapshot, "foreign.example.test", 8443, 0).Actions is null, "foreign action refusal");
        Require(RustNative.TryGetMachineActions(machineSnapshot, "mgmt.example.test", 8443, 1).Actions is null, "missing machine refusal");
        Guid machineId = Guid.Parse("0d9cc041-9db2-4e4c-b28b-1e41d7f472c1");
        MilaNativeCommandResult command = RustNative.TryFormatMachineCommand("stop", machineId, "porsche-0123456789abcdef0123456789abcdef");
        Require(command.Status == MilaNativeStatus.Ok && command.Command == $"stop {machineId:D} --json --request-id=porsche-0123456789abcdef0123456789abcdef", "bounded command format");
        foreach (string action in new[] { "stop --force", "stop\0ignored", "unknown" })
            Require(RustNative.TryFormatMachineCommand(action, machineId, "porsche-0123456789abcdef0123456789abcdef").Command is null, "action injection refusal");
        Require(RustNative.TryFormatMachineCommand("stop", machineId, null).Command is null, "mutation request required");
        Require(RustNative.TryFormatMachineCommand("stop", machineId, "id\0suffix").Command is null, "request truncation refusal");
        MilaNativeThreadCommandResult thread = RustNative.TryClassifyThreadCommand("thread ls");
        Require(thread.Status == MilaNativeStatus.Ok && thread.Kind == MilaThreadCommandKind.List, "thread command projection");
        Require(RustNative.TryClassifyThreadCommand("thread delete abc").Kind is null, "unknown thread command refusal");
        Require(RustNative.TryClassifyThreadCommand("thread ls\0ignored").Kind is null, "thread command truncation refusal");
        Require(RustNative.TryValidateTerminalAttach(0, 120, 40, true).IsValid, "terminal attach validation");
        Require(RustNative.TryValidateTerminalResize(120, 40, true).IsValid, "terminal resize validation");
        Require(RustNative.TryValidateTerminalInput(1024, true).IsValid, "terminal input validation");
        Require(!RustNative.TryValidateTerminalResize(0, 40, true).IsValid, "terminal resize bounds");
        Require(!RustNative.TryValidateTerminalInput((nuint)(1 << 20) + 1, true).IsValid, "terminal input bounds");
        MilaSessionListing listing = RustNative.DecodeSessionListing(Encoding.UTF8.GetBytes("{\"machines\":[{\"id\":\"0d9cc041-9db2-4e4c-b28b-1e41d7f472c1\",\"name\":\"test\",\"desired_state\":\"running\",\"observed_state\":\"running\",\"pinned\":false,\"read\":true,\"write\":true,\"manage\":true}],\"has_more\":true}"));
        Require(listing.HasMore && listing.Machines.Count == 1 && listing.Machines[0].Name == "test", "bounded live listing projection");
        bool refused = false;
        try { RustNative.DecodeSessionListing(Encoding.UTF8.GetBytes("{\"machines\":[{\"id\":\"bad\"}]}")); } catch (InvalidDataException) { refused = true; }
        Require(refused, "invalid listing refusal");
        Guid keyId = Guid.NewGuid();
        MilaSshKey key = MilaSshKeysController.DecodeListing(Encoding.UTF8.GetBytes($"{{\"keys\":[{{\"id\":\"{keyId:D}\",\"fingerprint\":\"SHA256:test\",\"algorithm\":\"ed25519\",\"current_device\":false}}]}}"))[0];
        Require(key.Id == keyId && key.Algorithm == "ed25519", "SSH key listing projection");
        bool revoked = false;
        var keys = new MilaSshKeysController(_ => Task.FromResult<IReadOnlyList<MilaSshKey>>(new[] { key }), (id, _) => { revoked = id == keyId; return Task.CompletedTask; });
        keys.LoadAsync(true).GetAwaiter().GetResult(); keys.RevokeAsync(key).GetAwaiter().GetResult();
        Require(revoked && keys.Status == MilaSshKeysStatus.Loaded, "SSH key revoke workflow");
        bool malformed = false; try { _ = MilaSshKeysController.DecodeListing(Encoding.UTF8.GetBytes("{\"keys\":[{\"id\":\"bad\"}]}")); } catch (InvalidDataException) { malformed = true; }
        Require(malformed, "invalid SSH key listing refusal");
        RustNative.CheckOutputBounds(route);
        Console.WriteLine("Windows Rust FFI smoke passed.");
    }

    private static void RefusesSnapshot(byte[] snapshot, string host, ushort port)
    {
        MilaNativeSnapshotResult result = RustNative.TryValidateSnapshot(snapshot, host, port, true);
        Require((int)result.Status == -4 && result.Summary is null, "invalid snapshot refusal");
    }
}
