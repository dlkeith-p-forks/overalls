defmodule OverallsProtocolCodecsContractTest do
  use Covenant.Case, component: "overalls_protocol.codecs"

  @tag obligation: "overalls_protocol.codecs.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      OverallsProtocol,
      OverallsProtocol.AddressPool,
      OverallsProtocol.AppRoute,
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
      OverallsProtocol.EditorPlatform,
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

  @tag obligation: "overalls_protocol.codecs.I4"
  test "reports reject contradictory or duplicate pool observations" do
    base = %{
      "sequence" => 1,
      "sampled_at" => "2026-01-01T00:00:00Z",
      "effective_cores" => 1,
      "effective_memory_bytes" => 1,
      "inventory" => %{},
      "pools" => []
    }

    pool = %{
      "id" => "123e4567-e89b-12d3-a456-426614174000",
      "total_bytes" => 10,
      "free_bytes" => 11,
      "allocations" => %{},
      "storage" => %{}
    }

    assert {:error, :invalid_message} = OverallsProtocol.report(%{base | "pools" => [pool]})
    pool2 = %{pool | "free_bytes" => 5}

    assert {:error, :invalid_message} =
             OverallsProtocol.report(%{base | "pools" => [pool2, pool2]})
  end

  @tag obligation: "overalls_protocol.codecs.I5"
  test "capacity observations require bounded complete proofs" do
    assert OverallsProtocol.Capacity.valid?(nil)
    refute OverallsProtocol.Capacity.valid?(%{"version" => 1, "cpu_headroom_millicores" => -1})

    proof = %{
      "execution_epoch" => 1,
      "generation" => 1,
      "outcome_id" => "123e4567-e89b-12d3-a456-426614174000",
      "compute" => true,
      "disk" => false
    }

    valid = %{
      "version" => 1,
      "cpu_headroom_millicores" => 0,
      "memory_headroom_bytes" => 0,
      "interval_us" => 1,
      "covered" => %{"123e4567-e89b-12d3-a456-426614174000" => proof}
    }

    assert OverallsProtocol.Capacity.valid?(valid)
    invalid = put_in(valid["covered"]["123e4567-e89b-12d3-a456-426614174000"]["generation"], 0)
    refute OverallsProtocol.Capacity.valid?(invalid)
  end

  @tag obligation: "overalls_protocol.codecs.I6"
  test "address pool rejects reserved slots and pairs inception" do
    assert {:error, :invalid_address} = OverallsProtocol.AddressPool.address(:customer, 1)
    assert {:error, :invalid_address} = OverallsProtocol.AddressPool.address(:customer, 65_535)
    assert {:ok, [control, paired]} = OverallsProtocol.AddressPool.addresses(:inception, 42)
    assert control == "10.40.0.42"
    assert paired == "10.41.0.42"
    assert {:ok, ["10.10.0.42"]} = OverallsProtocol.AddressPool.addresses(:customer, 42)
  end

  @tag obligation: "overalls_protocol.codecs.I7"
  test "application routes refuse secrets, fragments and unknown pages" do
    id = "123e4567-e89b-42d3-a456-426614174000"
    link = "overalls://overalls.example/machines/" <> id

    assert {:ok, route} = OverallsProtocol.AppRoute.parse(link)
    assert OverallsProtocol.AppRoute.format(route) == link

    for refused <- [
          "overalls://user:secret@overalls.example/machines",
          link <> "#fragment",
          link <> "?token=secret",
          "overalls://overalls.example/ssh/approve/porsche_approval_secret",
          "overalls://overalls.example/" <> String.duplicate("a", 2048)
        ] do
      assert {:error, :invalid_route} = OverallsProtocol.AppRoute.parse(refused)
    end
  end
end
