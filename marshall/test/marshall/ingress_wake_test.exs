defmodule Marshall.IngressWakeTest do
  use Marshall.DataCase, async: false
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Credentials,
    Host,
    HostLiveness,
    Ledger,
    Operation,
    Outcomes,
    ProvisionerControl,
    VirtualMachine,
    Wake,
    WakeRequest
  }

  alias Marshall.EditorFixture, as: F
  alias Marshall.Ingress.{ControlRequests, Relay}

  setup do
    previous = Application.get_env(:marshall, :ingress_editor_release)
    Application.put_env(:marshall, :ingress_editor_release, F.descriptor())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:marshall, :ingress_editor_release, previous),
        else: Application.delete_env(:marshall, :ingress_editor_release)
    end)

    F.new()
  end

  # @cc [owner:ghuntley,label:verification;security] editor-suspended-authority-before-wake
  # A suspended editor MUST establish identity without creating an execution
  # lease. Missing/revoked cookies MUST not enqueue wake. Authorized polls MUST
  # join one wake and receive a lease only after exact resume completion.
  test "a sleeping editor signs in, waits under fresh cookie authority and resumes", c do
    pause!(c)
    assert {:ok, _} = Marshall.Editor.launch(%{vm_id: c.vm.id}, actor: c.owner)
    cookie = F.cookie(c, c.owner)
    request = %{"version" => 1, "label" => cookie.label, "cookie" => nil}

    assert {:error, :authentication_required} =
             ControlRequests.handle("editor-open", c.service_token, request)

    assert Ledger.read!(WakeRequest, vm_id: c.vm.id) == []
    request = %{request | "cookie" => cookie.cookie}

    assert {:ok, %{pending: %{vm_id: id}}} =
             ControlRequests.handle("editor-open", c.service_token, request)

    assert id == c.vm.id
    assert {:ok, %{pending: _}} = ControlRequests.handle("editor-open", c.service_token, request)
    assert [wake] = Ledger.read!(WakeRequest, vm_id: c.vm.id)
    assert Ledger.read!(Marshall.Editor.Lease, vm_id: c.vm.id) == []
    assert {:ok, :waiting} = Wake.advance(wake.id)
    [resume] = Ledger.read!(Operation, vm_id: c.vm.id, kind: :resume)
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    {:ok, checkpoint} = OverallsProtocol.Checkpoint.decode(vm.current_checkpoint)
    observe!(resume, 3, :running, checkpoint)

    assert {:ok, %{grant: grant}} =
             ControlRequests.handle("editor-open", c.service_token, request)

    assert grant.binding.generation == resume.generation

    {:ok, identity} = OverallsProtocol.EditorName.parse(cookie.label)
    assert grant.binding.guest_account_id == identity.guest_account_id
  end

  test "revocation during a pending editor wait refuses the next renewal without a lease", c do
    cookie = F.cookie(c, c.owner)
    pause!(c)
    request = %{"version" => 1, "label" => cookie.label, "cookie" => cookie.cookie}
    assert {:ok, %{pending: _}} = ControlRequests.handle("editor-open", c.service_token, request)
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, c.token)

    assert {:error, :authentication_required} =
             ControlRequests.handle("editor-open", c.service_token, request)

    assert Ledger.read!(Marshall.Editor.Lease, vm_id: c.vm.id) == []
  end

  test "network activity cannot turn an explicit stop intent into wake demand", c do
    cookie = F.cookie(c, c.owner)
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    Ledger.intent!(vm, %{desired_state: :stopped, generation: vm.generation + 1})
    request = %{"version" => 1, "label" => cookie.label, "cookie" => cookie.cookie}

    assert {:error, :unauthorized} =
             ControlRequests.handle("editor-open", c.service_token, request)

    assert Ledger.read!(WakeRequest, vm_id: c.vm.id) == []
    assert Ledger.read!(Marshall.Editor.Lease, vm_id: c.vm.id) == []
  end

  # @cc [owner:ghuntley,label:verification;security] editor-relay-exact-peer-one-use
  # Original-gateway cookies MUST remain usable for an exact destination lease.
  # Wrong peer/ticket and duplicate consume MUST refuse. Revoking the original
  # login MUST revoke destination relay renewal without changing its binding.
  test "one-hop editor handoff preserves its cookie issuer and refuses replay and revocation",
       c do
    destination = enroll!(c.host.id, "10.90.0.12", c.service_token, c.service.name)
    origin_host = live_origin!()
    {origin_token, _} = Marshall.Ingress.Token.issue()

    origin =
      enroll!(origin_host.id, "10.90.0.11", origin_token, "origin-" <> Ash.UUID.generate())

    origin_context = %{c | service_token: origin_token}
    cookie = F.cookie(origin_context, c.owner)
    [login] = Ledger.read!(Marshall.Editor.Login, service_id: origin.id)
    assert login.host_id == c.vm.host_id
    assert login.host_id != origin.host_id
    request = %{"version" => 1, "label" => cookie.label, "cookie" => cookie.cookie}

    assert {:ok, %{grant: grant, relay: relay}} =
             ControlRequests.handle("editor-open", origin_token, request)

    assert grant.binding.host_id == c.host.id
    assert relay.destination_host_id == c.host.id
    assert relay.origin_host_id == origin_host.id
    [stored] = Ledger.read!(Relay)
    assert stored.destination_service_id == destination.id
    refute inspect(stored) =~ cookie.cookie

    wire = %{
      "version" => 1,
      "capability" => relay.capability,
      "ticket" => grant.ticket,
      "purpose" => "editor",
      "peer_address" => "10.90.0.11"
    }

    assert {:error, _} =
             ControlRequests.handle("relay-consume", c.service_token, %{
               wire
               | "peer_address" => "10.90.0.13"
             })

    assert {:ok, %{grant: consumed}} =
             ControlRequests.handle("relay-consume", c.service_token, wire)

    assert consumed.binding == grant.binding
    assert {:error, _} = ControlRequests.handle("relay-consume", c.service_token, wire)

    assert {:ok, %{grant: renewed}} =
             ControlRequests.handle("editor-renew", origin_token, %{
               "version" => 1,
               "stream_token" => grant.ticket
             })

    assert renewed.binding == grant.binding
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, c.token)
    assert {:error, _} = ControlRequests.handle("relay-renew", c.service_token, wire)
  end

  # @cc [owner:ghuntley,label:verification;security] editor-origin-host-revocation
  # Revoking only the original host MUST refuse new grants and wake demand,
  # origin renewal, destination consume and destination renewal while its gateway
  # credential and the destination execution remain current.
  for mode <- [:disabled, :draining, :retired, :disconnected, :unreported, :stale] do
    test "a #{mode} origin loses wake and relay authority", c do
      remote = remote!(c)

      assert {:ok, %{grant: first, relay: first_relay}} =
               ControlRequests.handle("editor-open", remote.token, remote.request)

      assert {:ok, %{grant: second, relay: second_relay}} =
               ControlRequests.handle("editor-open", remote.token, remote.request)

      first_wire = relay_wire(first, first_relay)
      second_wire = relay_wire(second, second_relay)
      assert {:ok, _} = ControlRequests.handle("relay-consume", c.service_token, first_wire)

      before =
        Enum.map(Ledger.read!(Relay), &{&1.id, &1.expires_at, &1.consumed_at}) |> Enum.sort()

      revoke_origin!(remote.host, unquote(mode))

      assert {:error, :unauthorized} =
               ControlRequests.handle("editor-open", remote.token, remote.request)

      assert {:error, :unauthorized} =
               ControlRequests.handle("editor-renew", remote.token, %{
                 "version" => 1,
                 "stream_token" => first.ticket
               })

      assert {:error, :unauthorized} =
               ControlRequests.handle("relay-renew", c.service_token, first_wire)

      assert {:error, :unauthorized} =
               ControlRequests.handle("relay-consume", c.service_token, second_wire)

      assert Enum.map(Ledger.read!(Relay), &{&1.id, &1.expires_at, &1.consumed_at}) |> Enum.sort() ==
               before

      assert length(Ledger.read!(Marshall.Editor.Lease, vm_id: c.vm.id)) == 2
      pause!(c)

      assert {:error, :unauthorized} =
               ControlRequests.handle("editor-open", remote.token, remote.request)

      assert Ledger.read!(WakeRequest, vm_id: c.vm.id) == []
    end
  end

  test "an enabled evacuating origin retains authority throughout the host authority window", c do
    remote = remote!(c)
    Ledger.update!(remote.host, :maintenance, %{maintenance_mode: :evacuating, enabled: true})

    Ledger.update!(remote.host, :report, %{
      reported_at: DateTime.add(Ledger.now(), -HostLiveness.capacity_ms() - 1, :millisecond)
    })

    assert {:ok, %{grant: grant, relay: relay}} =
             ControlRequests.handle("editor-open", remote.token, remote.request)

    wire = relay_wire(grant, relay)
    assert {:ok, _} = ControlRequests.handle("relay-consume", c.service_token, wire)
    assert {:ok, _} = ControlRequests.handle("relay-renew", c.service_token, wire)
    pause!(c)

    assert {:ok, %{pending: _}} =
             ControlRequests.handle("editor-open", remote.token, remote.request)

    assert [_] = Ledger.read!(WakeRequest, vm_id: c.vm.id)
  end

  @spec remote!(F.t()) :: %{host: Host.t(), token: String.t(), request: map()}
  defp remote!(c) do
    enroll!(c.host.id, "10.90.0.12", c.service_token, c.service.name)
    host = live_origin!()
    {token, _} = Marshall.Ingress.Token.issue()
    enroll!(host.id, "10.90.0.11", token, "origin-" <> Ash.UUID.generate())
    cookie = F.cookie(%{c | service_token: token}, c.owner)

    %{
      host: host,
      token: token,
      request: %{"version" => 1, "label" => cookie.label, "cookie" => cookie.cookie}
    }
  end

  # @cc [owner:ghuntley,label:verification;security] editor-origin-authenticated-host-fixture
  # A live origin fixture MUST open an authenticated v4 control session and
  # report through the production exchange. Capacity-only fixture reports MUST
  # NOT be treated as execution-session authority.
  @spec live_origin!() :: Host.t()
  defp live_origin! do
    fixture = Marshall.ComputeFixtures.host_fixture()
    {:ok, credential} = Credentials.rotate(fixture.host.id, 3600)
    connection = Marshall.TerminalFixtures.connect(credential.token, fixture.host.machine_id)

    {:ok, _} =
      ProvisionerControl.exchange_execution(
        credential.token,
        Map.merge(connection, %{
          report: %{fixture.report | sampled_at: Ledger.now()},
          acknowledgements: [],
          outcomes: []
        })
      )

    [host] = Ledger.read!(Host, id: fixture.host.id)
    host
  end

  @spec relay_wire(map(), map()) :: map()
  defp relay_wire(grant, relay),
    do: %{
      "version" => 1,
      "capability" => relay.capability,
      "ticket" => grant.ticket,
      "purpose" => "editor",
      "peer_address" => "10.90.0.11"
    }

  @spec revoke_origin!(
          Host.t(),
          :disabled | :draining | :retired | :disconnected | :unreported | :stale
        ) ::
          Host.t()
  defp revoke_origin!(host, :disabled),
    do: Ledger.update!(host, :configure, %{enabled: false})

  defp revoke_origin!(host, mode) when mode in [:draining, :retired],
    do: Ledger.update!(host, :maintenance, %{maintenance_mode: mode, enabled: false})

  defp revoke_origin!(host, :disconnected),
    do: Ledger.update!(host, :disconnect, %{connection_session_id: nil})

  defp revoke_origin!(host, :unreported),
    do: Ledger.update!(host, :connect, %{reported_at: nil})

  defp revoke_origin!(host, :stale),
    do:
      Ledger.update!(host, :report, %{
        reported_at: DateTime.add(Ledger.now(), -HostLiveness.authority_ms() - 1, :millisecond)
      })

  @spec enroll!(String.t(), String.t(), String.t(), String.t()) :: map()
  defp enroll!(host, address, token, name) do
    {:ok, service} =
      Marshall.Ingress.configure_service(
        %{
          name: name,
          host_id: host,
          role: :gateway,
          token: token,
          addresses: ["192.0.2.9"],
          relay_address: address,
          relay_port: 9445
        },
        actor: SystemActor.compute()
      )

    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)

    {:ok, _} =
      Marshall.Ingress.publish_host_key(%{token: token, public_key: key},
        actor: SystemActor.compute()
      )

    service
  end

  @spec pause!(map()) :: :ok
  defp pause!(c) do
    {:ok, operation} =
      Marshall.Compute.lifecycle(
        %{vm_id: c.vm.id, kind: :pause, idempotency_key: Ash.UUID.generate()},
        actor: c.owner
      )

    checkpoint = %{
      id: Ash.UUID.generate(),
      memory_bytes: c.vm.memory_bytes,
      state_bytes: 4096,
      compatibility: "sha256:" <> String.duplicate("a", 64),
      memory_sha256: "sha256:" <> String.duplicate("b", 64),
      state_sha256: "sha256:" <> String.duplicate("c", 64),
      manifest_sha256: "sha256:" <> String.duplicate("d", 64),
      dataset_guid: "71",
      snapshot_guid: "72"
    }

    observe!(operation, 2, :paused, checkpoint)
  end

  @spec observe!(
          Operation.t(),
          pos_integer(),
          :paused | :running,
          OverallsProtocol.Checkpoint.t()
        ) :: :ok
  defp observe!(operation, sequence, state, checkpoint) do
    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: operation.vm_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: sequence,
      state: state,
      compute_empty: state == :paused,
      disk_present: true,
      cleanup_complete: false,
      reason: :none,
      checkpoint: checkpoint
    }

    {:ok, typed} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(outcome))

    [vm] = Ledger.read!(VirtualMachine, id: operation.vm_id)

    assert {:ok, _} =
             Ledger.transaction(fn ->
               Ledger.lock!(Host, vm.host_id)
               Outcomes.ingest_locked!(vm.host_id, [typed])
             end)

    :ok
  end
end
