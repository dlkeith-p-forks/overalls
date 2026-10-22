using System.Text;
using System.Text.Json;
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
        SessionLifecycleSmoke.Run();
        AssertDeploymentPorts();
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
        Guid keyId = Guid.NewGuid();
        MilaNativeSessionActionResult invalidSession = RustNative.TrySessionMachineAction(0, machineId, "stop", "porsche-0123456789abcdef0123456789abcdef");
        Require(invalidSession.Status == MilaNativeStatus.InvalidRequest, "missing authenticated session refusal");
        MilaNativeSessionBytesResult invalidKeys = RustNative.TrySessionSshKeys(0);
        Require(invalidKeys.Status == MilaNativeStatus.InvalidRequest && invalidKeys.Data is null, "missing authenticated SSH key listing refusal");
        MilaNativeSessionActionResult invalidRevoke = RustNative.TrySessionSshKeyRevoke(
            0, keyId, "porsche-0123456789abcdef0123456789abcdef");
        Require(invalidRevoke.Status == MilaNativeStatus.InvalidRequest, "missing authenticated SSH key revoke refusal");
        Require(RustNative.TrySessionSshKeyRevoke(1, keyId, "bad-request").Status == MilaNativeStatus.InvalidRequest,
            "SSH key revoke request-id validation");
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
        MilaSshKey key = MilaSshKeysController.DecodeListing(Encoding.UTF8.GetBytes($"{{\"keys\":[{{\"id\":\"{keyId:D}\",\"fingerprint\":\"SHA256:test\",\"algorithm\":\"ed25519\",\"current_device\":false}}]}}"))[0];
        Require(key.Id == keyId && key.Algorithm == "ed25519", "SSH key listing projection");
        bool revoked = false;
        var keys = new MilaSshKeysController(_ => Task.FromResult<IReadOnlyList<MilaSshKey>>(new[] { key }), (id, _) => { revoked = id == keyId; return Task.CompletedTask; });
        keys.LoadAsync(true).GetAwaiter().GetResult(); keys.RevokeAsync(key).GetAwaiter().GetResult();
        Require(revoked && keys.Status == MilaSshKeysStatus.Loaded, "SSH key revoke workflow");
        bool malformed = false; try { _ = MilaSshKeysController.DecodeListing(Encoding.UTF8.GetBytes("{\"keys\":[{\"id\":\"bad\"}]}")); } catch (InvalidDataException) { malformed = true; }
        Require(malformed, "invalid SSH key listing refusal");
        var hello = new FakeHello(MilaWindowsHelloAvailability.Available, MilaWindowsHelloVerification.Verified);
        var lockController = new MilaAppLockController(hello);
        Require(lockController.RefreshAvailabilityAsync().GetAwaiter().GetResult() == MilaAppLockState.Unlocked, "Hello availability");
        lockController.Lock(); Require(lockController.IsLocked, "app lock state");
        Require(lockController.UnlockAsync().GetAwaiter().GetResult() && !lockController.IsLocked && hello.LastMessage == "Unlock Mila", "Hello unlock");
        var unavailable = new MilaAppLockController(new FakeHello(MilaWindowsHelloAvailability.Unavailable, MilaWindowsHelloVerification.Verified));
        Require(unavailable.RefreshAvailabilityAsync().GetAwaiter().GetResult() == MilaAppLockState.Unavailable, "Hello unavailable state");
        RustNative.CheckOutputBounds(route);
        AssertRoutes();
        Console.WriteLine("Windows Rust FFI smoke passed.");
    }

    private static void AssertRoutes()
    {
        MilaRoute? machines = MilaRouteParser.Parse("overalls://mgmt.example.test/machines");
        Require(machines is { Kind: MilaRouteKind.Machines, Host: "mgmt.example.test" }, "machines activation route");
        MilaRoute? machine = MilaRouteParser.Parse("overalls://mgmt.example.test/machines/0d9cc041-9db2-4e4c-b28b-1e41d7f472c1");
        Require(machine is { Kind: MilaRouteKind.Machine } && machine.Value.Id.HasValue, "machine activation route");
        foreach (string invalid in new[] { "https://mgmt.example.test/machines", "overalls://MGMT.example.test/machines", "overalls://mgmt.example.test/machines?x=1", "overalls://mgmt.example.test/unknown", "overalls://mgmt.example.test/machines/new" })
            Require(MilaRouteParser.Parse(invalid) is null, "invalid activation route refusal");
    }

    private static void AssertDeploymentPorts()
    {
        MilaDeployment? legacy = JsonSerializer.Deserialize<MilaDeployment>("{\"Host\":\"mgmt.example.test\"}")?.Normalize();
        Require(legacy is { Host: "mgmt.example.test", Port: MilaDeployment.DefaultPort }, "legacy deployment defaults to Porsche port 22");
        MilaDeployment explicitPort = new("mgmt.example.test", 2222);
        MilaDeployment? roundTrip = JsonSerializer.Deserialize<MilaDeployment>(JsonSerializer.Serialize(explicitPort));
        Require(roundTrip is { Host: "mgmt.example.test", Port: 2222 }, "deployment port persists as typed value");
    }

    private sealed class FakeHello(MilaWindowsHelloAvailability availability, MilaWindowsHelloVerification result) : IMilaWindowsHelloVerifier
    {
        internal string? LastMessage { get; private set; }
        public Task<MilaWindowsHelloAvailability> CheckAvailabilityAsync(CancellationToken cancellationToken = default) => Task.FromResult(availability);
        public Task<MilaWindowsHelloVerification> VerifyAsync(string message, CancellationToken cancellationToken = default) { LastMessage = message; return Task.FromResult(result); }
    }

    private static void RefusesSnapshot(byte[] snapshot, string host, ushort port)
    {
        MilaNativeSnapshotResult result = RustNative.TryValidateSnapshot(snapshot, host, port, true);
        Require((int)result.Status == -4 && result.Summary is null, "invalid snapshot refusal");
    }
}
