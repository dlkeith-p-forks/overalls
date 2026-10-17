defmodule OverallsProtocolCodecsContractTest do
  use Covenant.Case, component: "overalls_protocol.codecs"

  @tag obligation: "overalls_protocol.codecs.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      OverallsProtocol,
      OverallsProtocol.AddressPool,
      OverallsProtocol.Cadence,
      OverallsProtocol.Capacity,
      OverallsProtocol.CloneControl,
      OverallsProtocol.Control.Client,
      OverallsProtocol.Control.Close,
      OverallsProtocol.Control.Envelope,
      OverallsProtocol.DiskLayout,
      OverallsProtocol.DiskTransfer,
      OverallsProtocol.EditorAssets,
      OverallsProtocol.EditorConnect,
      OverallsProtocol.EditorLogin,
      OverallsProtocol.EditorName,
      OverallsProtocol.EditorRelease,
      OverallsProtocol.EditorStream,
      OverallsProtocol.EgressAttribution,
      OverallsProtocol.Execution,
      OverallsProtocol.FleetCertificate,
      OverallsProtocol.GuestAgents,
      OverallsProtocol.ImageManifest,
      OverallsProtocol.InceptionControl,
      OverallsProtocol.InceptionExchange,
      OverallsProtocol.InceptionName,
      OverallsProtocol.InceptionObservation,
      OverallsProtocol.InceptionParent,
      OverallsProtocol.InceptionPublic,
      OverallsProtocol.Inference,
      OverallsProtocol.IngressCatalog,
      OverallsProtocol.IngressConnect,
      OverallsProtocol.IngressName,
      OverallsProtocol.IngressRoute,
      OverallsProtocol.Integration,
      OverallsProtocol.Machine,
      OverallsProtocol.MachineName,
      OverallsProtocol.NestedStream,
      OverallsProtocol.PrivateServices,
      OverallsProtocol.ProfilePolicy,
      OverallsProtocol.ProxyHeader,
      OverallsProtocol.Readiness,
      OverallsProtocol.Relocation,
      OverallsProtocol.RelocationCleanup,
      OverallsProtocol.RelocationDestinationCleanup,
      OverallsProtocol.RelocationDestinationRevocation,
      OverallsProtocol.RelocationImport,
      OverallsProtocol.RelocationKeyRetirement,
      OverallsProtocol.RelocationKeys,
      OverallsProtocol.RelocationProbe,
      OverallsProtocol.RelocationReadiness,
      OverallsProtocol.RelocationReceive,
      OverallsProtocol.RelocationRevocation,
      OverallsProtocol.RelocationSnapshotCleanup,
      OverallsProtocol.RelocationSource,
      OverallsProtocol.Resize,
      OverallsProtocol.SSHCommand,
      OverallsProtocol.SSHHostCertificate,
      OverallsProtocol.SSHKey,
      OverallsProtocol.SSHManagement,
      OverallsProtocol.SSHOnboarding,
      OverallsProtocol.SSHTrust,
      OverallsProtocol.Storage,
      OverallsProtocol.Terminal,
      OverallsProtocol.TerminalWindow,
      OverallsProtocol.TransferSSH,
      OverallsProtocol.VMShape,
      OverallsProtocol.View,
      OverallsProtocol.WebLogin,
      OverallsProtocol.WebSocket.Connection,
      OverallsProtocol.WebSocket.Frame,
      OverallsProtocol.WebSocket.Handshake,
      OverallsProtocol.WebStream,
      OverallsProtocol.WorkloadBundle,
      OverallsProtocol.WorkspaceSource
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "overalls_protocol.codecs.I2"
  test "wire decoder bounds input and accepts only JSON objects" do
    assert {:ok, %{"ok" => true}} = OverallsProtocol.decode(~s({"ok":true}))
    assert {:error, :invalid_message} = OverallsProtocol.decode(~s([1,2,3]))
    assert {:error, :invalid_message} = OverallsProtocol.decode("not-json")

    assert {:error, :message_too_large} =
             OverallsProtocol.decode(String.duplicate("x", OverallsProtocol.max_body() + 1))
  end

  @tag obligation: "overalls_protocol.codecs.I3"
  test "UUID validation is strict and report nil remains unknown" do
    assert OverallsProtocol.uuid?("123e4567-e89b-12d3-a456-426614174000")
    refute OverallsProtocol.uuid?("123E4567-e89b-12d3-a456-426614174000")
    refute OverallsProtocol.uuid?("not-a-uuid")
    assert {:ok, nil} = OverallsProtocol.report(nil)
  end
end
