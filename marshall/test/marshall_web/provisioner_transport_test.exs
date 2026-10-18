defmodule MarshallWeb.ProvisionerTransportTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Lilly.Control.Client
  alias Marshall.Compute.{Credentials, Ledger, Operation}
  @certificate Path.expand("../fixtures/tls/localhost.pem", __DIR__)
  @key Path.expand("../fixtures/tls/localhost.key", __DIR__)
  @ca Path.expand("../fixtures/tls/ca.pem", __DIR__)

  defmodule Reply do
    @moduledoc """
    Test-only control endpoint with a fixed reply. Status 200 upgrades and
    answers every request with the JSON document (anything else answers
    "unavailable"); other statuses refuse the upgrade itself. The owner sees
    `{:http_request, path}` per upgrade refusal and per request, the latter as
    the request's provisioner route path.
    """
    @behaviour Plug
    import Plug.Conn
    alias OverallsProtocol.Control.Envelope

    def init(options), do: options

    def call(conn, {owner, 200, body, _headers}) do
      conn
      |> upgrade_adapter(:websocket, {__MODULE__.Socket, {owner, body}, []})
      |> halt()
    end

    def call(conn, {owner, status, body, headers}) do
      send(owner, {:http_request, conn.request_path})

      Enum.reduce(headers, conn, fn {key, value}, conn -> put_resp_header(conn, key, value) end)
      |> send_resp(status, body)
    end

    defmodule Socket do
      @moduledoc false
      @behaviour WebSock

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_in({text, [opcode: :text]}, {owner, body} = state) do
        case Envelope.decode(text) do
          {:ok, {:hello, _hello}} ->
            welcome = %{conn: "reply", heartbeat_ms: 5_000, limits: %{"in_flight" => 64}}
            {:push, {:text, Envelope.encode({:welcome, welcome})}, state}

          {:ok, {:req, %{id: id, op: "lilly." <> action}}} ->
            send(owner, {:control_request, "lilly." <> action})

            result =
              case JSON.decode(body) do
                {:ok, value} when is_map(value) -> {:ok, value}
                _ -> {:error, "unavailable"}
              end

            {:push, {:text, Envelope.encode({:res, %{id: id, result: result}})}, state}

          {:ok, {:ping, n}} ->
            {:push, {:text, Envelope.encode({:pong, n})}, state}

          _ ->
            {:ok, state}
        end
      end

      @impl true
      def handle_info(_message, state), do: {:ok, state}
    end
  end

  setup do
    fixture = host_fixture(%{machine_id: "sha256:" <> String.duplicate("f", 64)})
    owner = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
    {:ok, credential} = Credentials.rotate(fixture.host.id, 3600)

    report = %{
      fixture.report
      | inventory: Map.put(fixture.report.inventory, "terminal_protocol", 2)
    }

    Map.merge(fixture, %{credential: credential, vm: vm, owner: owner, report: report})
  end

  test "Lilly reports and receives durable commands over verified HTTPS", context do
    base_url = listener(Marshall.AudiControl.FleetPlug, :https)
    {:ok, client} = client(context, base_url, cacertfile: @ca)
    {:ok, session} = Client.open(client, Ash.UUID.generate())

    assert {:ok, %{commands: [command]}} =
             Client.exchange_execution(client, session, context.report, [], [])

    assert command.vm_id == context.vm.id

    assert {:ok, %{commands: [^command]}} =
             Client.exchange_execution(client, session, nil, [command.id], [])

    assert [%{status: :acknowledged}] = Ledger.read!(Operation, id: command.id)
    assert {:ok, :ok} = Credentials.revoke(context.host.id)
    assert {:error, :unauthorized} = Client.exchange_execution(client, session, nil, [], [])
  end

  test "terminal upgrade survives the complete fleet Plug pipeline and authenticates hello",
       context do
    alias Marshall.Test.WebSocketClient, as: Websocket
    alias OverallsProtocol.Terminal, as: Codec
    base_url = listener(MarshallWeb.FleetEndpoint, :https)
    {:ok, client} = client(context, base_url, cacertfile: @ca)
    {:ok, session} = Client.open(client, Ash.UUID.generate())

    assert {:ok, socket} =
             Websocket.open(base_url, "/api/provisioners/v4/stream",
               headers: [{"authorization", "Lilly " <> client.token}],
               cacertfile: @ca
             )

    :ok =
      Websocket.send_binary(
        socket,
        Codec.encode_control_frame(%{
          type: :hello,
          host_id: context.host.id,
          session_id: session.session_id,
          epoch: session.epoch
        })
      )

    assert {:ok, {:binary, reply}} = Websocket.recv(socket, 5000)
    assert reply == Codec.encode_control_frame(%{type: :hello_response, interval_ms: 1000})
    assert {:ok, %{message: %{type: :hello_response}}} = Codec.decode_frame(reply)
    Websocket.close(socket)
  end

  test "execution commands carry the VM owner over verified HTTPS", context do
    base_url = listener(Marshall.AudiControl.FleetPlug, :https)
    {:ok, client} = client(context, base_url, cacertfile: @ca)
    {:ok, session} = Client.open(client, Ash.UUID.generate())
    {:ok, %{commands: [command]}} = Client.exchange_execution(client, session, nil, [], [])
    assert command.owner_id == context.owner.id
    assert {:ok, :ok} = Credentials.revoke(context.host.id)

    assert {:error, :unauthorized} =
             Client.exchange_execution(client, session, nil, [], [])
  end

  test "independent frontend peer hops forward controls and binary viewer traffic over TLS",
       context do
    alias OverallsProtocol.Terminal
    alias Marshall.Test.WebSocketClient, as: Websocket
    alias Marshall.Terminal.{Directory, Remote}
    base_url = listener(MarshallWeb.FleetEndpoint, :https)
    previous_url = Application.get_env(:marshall, :terminal_peer_url)
    previous_ca = Application.get_env(:marshall, :terminal_peer_ca)
    Application.put_env(:marshall, :terminal_peer_url, base_url)
    Application.put_env(:marshall, :terminal_peer_ca, @ca)

    on_exit(fn ->
      Application.put_env(:marshall, :terminal_peer_url, previous_url)
      Application.put_env(:marshall, :terminal_peer_ca, previous_ca)
    end)

    {:ok, client} = client(context, base_url, cacertfile: @ca)
    {:ok, session} = Client.open(client, Ash.UUID.generate())

    {:ok, host_socket} =
      Websocket.open(base_url, "/api/provisioners/v4/stream",
        headers: [{"authorization", "Lilly " <> client.token}],
        cacertfile: @ca
      )

    :ok =
      Websocket.send_binary(
        host_socket,
        Terminal.encode_control_frame(%{
          type: :hello,
          host_id: context.host.id,
          session_id: session.session_id,
          epoch: session.epoch
        })
      )

    assert {:ok, {:binary, _hello}} = Websocket.recv(host_socket, 5000)
    assert {:ok, location} = Directory.lookup(context.host.id)
    {:ok, remote} = Remote.start(self(), location)
    ref = make_ref()
    placement = context.vm.current_placement_id
    request = %{type: :listing, vm_id: context.vm.id, placement_id: placement, execution_epoch: 1}
    send(remote, {:relay_control, %{caller: self(), ref: ref, message: request}})
    assert {:ok, {:binary, control}} = Websocket.recv(host_socket, 5000)
    assert {:ok, %{message: ^request}} = Terminal.decode_frame(control)
    response = %{type: :listed, vm_id: context.vm.id, sessions: []}
    :ok = Websocket.send_binary(host_socket, Terminal.encode_control_frame(response))
    assert_receive {:relay_reply, ^ref, {:ok, ^response}}, 5000

    {:ok, remote} = Remote.start(self(), location)

    message = %{
      type: :attach,
      cols: 80,
      rows: 24,
      vm_id: context.vm.id,
      placement_id: placement,
      execution_epoch: 1,
      guest_session_id: 1,
      mode: :rw,
      cursor: 0
    }

    send(remote, {:viewer_attach, %{caller: self(), ref: make_ref(), message: message}})
    assert {:ok, {:binary, control}} = Websocket.recv(host_socket, 5000)
    assert {:ok, %{message: %{type: :attach, channel: channel}}} = Terminal.decode_frame(control)

    :ok =
      Websocket.send_binary(
        host_socket,
        Terminal.encode_control_frame(%{
          type: :attached,
          replay_bytes: 0,
          channel: channel,
          ok: true,
          guest_session_id: 1,
          from: 0,
          reason: nil
        })
      )

    assert_receive {:terminal_attached, %{channel: ^channel}}, 5000
    bytes = <<0, 255, 27, 91, 109>>
    :ok = Websocket.send_binary(host_socket, Terminal.encode_data_frame(channel, 1, bytes))
    assert_receive {:terminal_output, ^bytes}, 5000
    send(remote, {:viewer_input, channel, bytes})
    assert {:ok, {:binary, data}} = Websocket.recv(host_socket, 5000)
    assert {:ok, %{channel: ^channel, bytes: ^bytes, sequence: 1}} = Terminal.decode_frame(data)
    GenServer.stop(remote)
    Websocket.close(host_socket)
  end

  @tag :tmp_dir
  test "cancelled source revocation fences a local permit through the HTTPS worker", c do
    alias Marshall.Compute.{Host, Relocation, RelocationCapacity, Reservation, VirtualMachine}
    [operation] = Ledger.read!(Operation, vm_id: c.vm.id)
    Ledger.update!(operation, :complete, %{})
    # An originally stopped source is snapshotted without a relocation stop.
    vm = Ledger.intent!(c.vm, %{desired_state: :stopped})
    Ledger.update!(vm, :observe, %{observed_state: :stopped})
    [hold] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
    Ledger.update!(hold, :release_compute, %{})
    destination = host_fixture()

    for fixture <- [c, destination] do
      {:ok, epoch} = Marshall.Compute.HostReports.connect(fixture.host.id)

      assert {:ok, :ok} =
               Marshall.Compute.HostReports.ingest(fixture.host.id, epoch, %{
                 fixture.report
                 | sequence: 1,
                   sampled_at: DateTime.utc_now()
               })
    end

    {:ok, relocation} =
      Ledger.transaction(fn ->
        hosts =
          Host |> Ledger.read!() |> Enum.sort_by(& &1.id) |> Enum.map(&Ledger.lock!(Host, &1.id))

        vm = Ledger.lock!(VirtualMachine, c.vm.id)
        RelocationCapacity.reserve_locked!(vm, hosts, c.owner, Ash.UUID.generate())
      end)

    public = c.host.transfer_endpoint["host_key"]
    Ledger.update!(relocation, :record_key, %{destination_public_key: public})
    base = listener(Marshall.AudiControl.FleetPlug, :https)
    {:ok, client} = client(c, base, cacertfile: @ca)
    {:ok, session} = Client.open(client, Ash.UUID.generate())
    {:ok, %{commands: [source]}} = Client.exchange_relocation_source(client, session, [])

    descriptor =
      Map.put(source.intent, :stream, %{
        source_dataset_guid: "100",
        to_guid: "200"
      })

    File.chmod!(c.tmp_dir, 0o700)
    now = System.system_time(:second)
    wire = OverallsProtocol.Relocation.encode_descriptor(descriptor)
    assert :ok = Lilly.Transfer.PermitJournal.grant(c.tmp_dir, wire, public, 1, now + 180, now)

    assert {:ok, _} =
             Marshall.Compute.cancel_relocation(%{relocation_id: relocation.id}, actor: c.owner)

    assert {:ok, %{commands: [command]}} =
             Client.exchange_relocation_revocation(client, session, [])

    result = Map.take(command, [:id, :placement_id, :execution_epoch])
    {:ok, credential} = Credentials.rotate(destination.host.id, 3600)
    {:ok, foreign} = client(Map.put(destination, :credential, credential), base, cacertfile: @ca)
    {:ok, foreign_session} = Client.open(foreign, Ash.UUID.generate())

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_revocation(foreign, foreign_session, [result])

    worker_base = listener({Marshall.RelocationKeyProbe, self()}, :https)

    pid =
      start_supervised!(
        {Lilly.Transfer.SourceRuntime,
         mode: :revoke,
         store: nil,
         config: %Lilly.Control.Config{
           client: Marshall.LillyControl.connect(%{client | base_url: worker_base}),
           state_dir: c.tmp_dir,
           cgroup_path: "/sys/fs/cgroup/lilly.slice",
           pools: [],
           transfer_state_dir: c.tmp_dir
         },
         session: session,
         owner: self()}
      )

    assert_receive {:key_exchange_complete, 200}, 3000
    assert_receive {:key_exchange_complete, 200}, 5000
    assert [%{source_revoked_at: confirmed}] = Ledger.read!(Relocation, id: relocation.id)
    assert confirmed != nil
    assert {:error, _} = Lilly.Transfer.PermitJournal.for_key(c.tmp_dir, c.host.id, public, now)

    assert {:error, _} =
             Lilly.Transfer.PermitJournal.grant(c.tmp_dir, wire, public, 2, now + 180, now)

    assert {:ok, %{commands: [], acknowledgements: [_]}} =
             Client.exchange_relocation_revocation(client, session, [result])

    assert {:ok, _} = Client.open(client, Ash.UUID.generate())
    assert_receive {:transfer_revocation_fenced, ^pid, :stale_connection}, 5000
    stop_supervised!(Lilly.Transfer.SourceRuntime)

    destination_root = Path.join(c.tmp_dir, "destination")
    :ok = Lilly.Host.PrivateFiles.directory(destination_root)

    destination_worker =
      start_supervised!(
        {Lilly.Transfer.KeyRuntime,
         mode: :cancel,
         root: destination_root,
         client: Marshall.LillyControl.connect(%{foreign | base_url: worker_base}),
         session: foreign_session,
         owner: self()}
      )

    assert_receive {:key_exchange_complete, 200}, 3000
    assert_receive {:key_exchange_complete, 200}, 5000

    assert [%{destination_revoked_at: destination_confirmed}] =
             Ledger.read!(Relocation, id: relocation.id)

    assert destination_confirmed != nil

    assert {:error, _} =
             Lilly.Transfer.Key.ensure(
               destination_root,
               destination.host.id,
               relocation.id,
               relocation.destination_placement_id
             )

    {:ok, next_destination_session} = Client.open(foreign, Ash.UUID.generate())

    assert_receive {:transfer_destination_revocation_fenced, ^destination_worker,
                    :stale_connection},
                   5000

    stop_supervised!(Lilly.Transfer.KeyRuntime)
    foreign_session = next_destination_session

    assert {:ok, %{commands: [destination_cleanup]}} =
             Client.exchange_relocation_destination_cleanup(foreign, foreign_session, [])

    assert destination_cleanup.intent.destination.host_id == destination.host.id

    cleanup_worker =
      start_supervised!(
        {Lilly.Transfer.SourceRuntime,
         mode: :destination_cleanup,
         store: nil,
         config: %Lilly.Control.Config{
           client: Marshall.LillyControl.connect(%{foreign | base_url: worker_base}),
           state_dir: destination_root,
           cgroup_path: "/sys/fs/cgroup/lilly.slice",
           pools: [],
           transfer_state_dir: destination_root
         },
         session: foreign_session,
         owner: self()}
      )

    assert_receive {:key_exchange_complete, 200}, 3000
    assert_receive {:key_exchange_complete, 200}, 5000
    # No configured destination pool means no physical receipt may be invented.
    assert [%{destination_cleaned_at: nil}] = Ledger.read!(Relocation, id: relocation.id)
    {:ok, next_destination_session} = Client.open(foreign, Ash.UUID.generate())

    assert_receive {:transfer_destination_cleanup_fenced, ^cleanup_worker, :stale_connection},
                   5000

    stop_supervised!(Lilly.Transfer.SourceRuntime)
    foreign_session = next_destination_session

    assert {:error, :stale_connection} =
             Client.exchange_relocation_revocation(client, session, [result])

    {:ok, fresh} = Client.open(client, Ash.UUID.generate())
    assert {:ok, %{commands: []}} = Client.exchange_relocation_snapshot_cleanup(client, fresh, [])

    # The originally stopped source is restored by a fenced stop only.
    for {state, sequence} <- [stopped: 1] do
      assert {:ok, :restoring_source} =
               Marshall.Compute.RelocationCoordinator.advance(relocation.id)

      assert {:ok, %{commands: [operation]}} =
               Client.exchange_execution(client, fresh, nil, [], [])

      outcome = %{
        id: Ash.UUID.generate(),
        vm_id: c.vm.id,
        placement_id: operation.placement_id,
        execution_epoch: operation.execution_epoch,
        generation: operation.generation,
        operation_id: operation.id,
        sequence: sequence,
        state: state,
        compute_empty: state == :stopped,
        disk_present: true,
        cleanup_complete: false,
        reason: :none
      }

      assert {:ok, _} = Client.exchange_execution(client, fresh, nil, [], [outcome])
    end

    assert {:ok, :source_restored_pending_cleanup} =
             Marshall.Compute.RelocationCoordinator.advance(relocation.id)

    assert {:ok, %{commands: [prune]}} =
             Client.exchange_relocation_snapshot_cleanup(client, fresh, [])

    prune_result = Map.take(prune, [:id, :placement_id, :execution_epoch])

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_snapshot_cleanup(foreign, foreign_session, [prune_result])

    assert {:ok, %{commands: [], acknowledgements: [_]}} =
             Client.exchange_relocation_snapshot_cleanup(client, fresh, [prune_result])

    assert {:ok, %{commands: [], acknowledgements: [_]}} =
             Client.exchange_relocation_snapshot_cleanup(client, fresh, [prune_result])

    assert [%{source_snapshots_cleaned_at: cleaned}] = Ledger.read!(Relocation, id: relocation.id)
    assert cleaned != nil

    assert [%{committed_at: nil, finished_at: nil}] = Ledger.read!(Relocation, id: relocation.id)
    # Synthetic physical evidence tests HTTPS receipt handling, not native cleanup.
    destination_result = %{
      id: relocation.id,
      placement_id: relocation.destination_placement_id,
      execution_epoch: relocation.destination_epoch
    }

    assert {:ok, %{commands: [], acknowledgements: [_]}} =
             Client.exchange_relocation_destination_cleanup(foreign, foreign_session, [
               destination_result
             ])

    assert {:ok, :cancelled} = Marshall.Compute.RelocationCoordinator.advance(relocation.id)
    assert [%{finished_at: finished}] = Ledger.read!(Relocation, id: relocation.id)
    assert finished != nil
  end

  @tag :tmp_dir
  test "relocation control drives handoff, readiness and source retirement over verified HTTPS",
       context do
    alias Marshall.Compute.{Host, Relocation, RelocationCapacity, VirtualMachine}
    [operation] = Ledger.read!(Operation, vm_id: context.vm.id)
    Ledger.update!(operation, :complete, %{})
    Ledger.update!(context.vm, :observe, %{observed_state: :running})
    destination = host_fixture()
    {:ok, credential} = Credentials.rotate(destination.host.id, 3600)

    for fixture <- [context, destination] do
      {:ok, epoch} = Marshall.Compute.HostReports.connect(fixture.host.id)

      assert {:ok, :ok} =
               Marshall.Compute.HostReports.ingest(fixture.host.id, epoch, %{
                 fixture.report
                 | sequence: 1,
                   sampled_at: DateTime.utc_now()
               })
    end

    {:ok, relocation} =
      Ledger.transaction(fn ->
        hosts =
          Host |> Ledger.read!() |> Enum.sort_by(& &1.id) |> Enum.map(&Ledger.lock!(Host, &1.id))

        vm = Ledger.lock!(VirtualMachine, context.vm.id)
        RelocationCapacity.reserve_locked!(vm, hosts, context.owner, Ash.UUID.generate())
      end)

    assert relocation.source_endpoint == context.host.transfer_endpoint

    assert [_] =
             Oban.Testing.all_enqueued(
               repo: Marshall.Repo,
               worker: Marshall.Compute.Workers.PrepareRelocationKey
             )

    base = listener(Marshall.AudiControl.FleetPlug, :https)
    {:ok, client} = client(Map.put(destination, :credential, credential), base, cacertfile: @ca)
    {:ok, session} = Client.open(client, Ash.UUID.generate())

    assert {:ok, %{commands: [command], acknowledgements: []}} =
             Client.exchange_relocation_keys(client, session, [])

    assert command.id == relocation.id
    assert command.placement_id == relocation.destination_placement_id
    assert {:ok, %{commands: [^command]}} = Client.exchange_relocation_keys(client, session, [])

    public = context.host.transfer_endpoint["host_key"]

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_keys(client, session, [
               %{
                 id: relocation.id,
                 placement_id: command.placement_id,
                 execution_epoch: command.execution_epoch,
                 public_key: public
               },
               %{
                 id: Ash.UUID.generate(),
                 placement_id: command.placement_id,
                 execution_epoch: command.execution_epoch,
                 public_key: public
               }
             ])

    assert [%{destination_public_key: nil}] = Ledger.read!(Relocation, id: relocation.id)

    File.chmod!(context.tmp_dir, 0o700)

    worker_base = listener({Marshall.RelocationKeyProbe, self()}, :https)

    start_supervised!(
      {Lilly.Transfer.KeyRuntime,
       root: context.tmp_dir,
       client: Marshall.LillyControl.connect(%{client | base_url: worker_base}),
       session: session,
       owner: self()}
    )

    assert_receive {:key_exchange_complete, 200}, 3000
    assert_receive {:key_exchange_complete, 200}, 5000
    assert [%{destination_public_key: prepared}] = Ledger.read!(Relocation, id: relocation.id)
    assert OverallsProtocol.TransferSSH.public_key?(prepared)
    stop_supervised!(Lilly.Transfer.KeyRuntime)

    assert {:ok, result} =
             Lilly.Transfer.KeyRuntime.prepare(context.tmp_dir, destination.host.id, command)

    assert {:ok, %{commands: [], acknowledgements: [id]}} =
             Client.exchange_relocation_keys(client, session, [result])

    assert id == relocation.id

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_keys(client, session, [
               %{result | execution_epoch: result.execution_epoch + 1}
             ])

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_keys(client, session, [
               %{result | placement_id: Ash.UUID.generate()}
             ])

    assert {:ok, %{commands: [], acknowledgements: [^id]}} =
             Client.exchange_relocation_keys(client, session, [result])

    assert [%{destination_public_key: public}] = Ledger.read!(Relocation, id: relocation.id)
    assert public == result.public_key

    conflicting = %{result | public_key: context.host.transfer_endpoint["host_key"]}

    assert {:error, :outcome_conflict} =
             Client.exchange_relocation_keys(client, session, [conflicting])

    {:ok, foreign} = client(context, base, cacertfile: @ca)
    {:ok, foreign_session} = Client.open(foreign, Ash.UUID.generate())

    # ADR-0199: fresh connectivity proof gates memory-preserving suspension;
    # only its exact checkpoint permits the coherent disk/RAM stream.
    assert {:ok, %{commands: []}} =
             Client.exchange_relocation_source(foreign, foreign_session, [])

    [keyed] = Ledger.read!(Relocation, id: relocation.id)
    [running] = Ledger.read!(VirtualMachine, id: context.vm.id)
    Marshall.RelocationProbeFixture.applied!(keyed, running)

    for host <- [context.host, destination.host] do
      Ledger.update!(host, :report, %{reported_at: Ledger.now()})
    end

    assert {:ok, :stopping} = Marshall.Compute.RelocationCoordinator.advance(relocation.id)

    assert {:ok, %{commands: [stop]}} =
             Client.exchange_execution(foreign, foreign_session, nil, [], [])

    assert stop.kind == :pause

    checkpoint = %{
      id: Ash.UUID.generate(),
      memory_bytes: context.vm.memory_bytes,
      state_bytes: 4096,
      compatibility: "sha256:" <> String.duplicate("a", 64),
      memory_sha256: "sha256:" <> String.duplicate("b", 64),
      state_sha256: "sha256:" <> String.duplicate("c", 64),
      manifest_sha256: "sha256:" <> String.duplicate("d", 64),
      dataset_guid: "81",
      snapshot_guid: "82"
    }

    event = %{
      id: Ash.UUID.generate(),
      vm_id: stop.vm_id,
      placement_id: stop.placement_id,
      execution_epoch: stop.execution_epoch,
      generation: stop.generation,
      operation_id: stop.id,
      sequence: 1,
      state: :paused,
      checkpoint: checkpoint,
      compute_empty: true,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    assert {:ok, _} = Client.exchange_execution(foreign, foreign_session, nil, [], [event])

    assert {:ok, %{commands: [source_request]}} =
             Client.exchange_relocation_source(foreign, foreign_session, [])

    assert source_request.public_key == result.public_key
    assert source_request.intent.source.placement_id == context.vm.current_placement_id
    assert {:ok, %{commands: []}} = Client.exchange_relocation_source(client, session, [])

    source_result = %{
      id: source_request.id,
      descriptor:
        Map.put(source_request.intent, :stream, %{
          source_dataset_guid: "100",
          to_guid: "200"
        })
    }

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_source(client, session, [source_result])

    assert {:ok, %{commands: [], acknowledgements: [source_id]}} =
             Client.exchange_relocation_source(foreign, foreign_session, [source_result])

    assert source_id == source_request.id

    assert {:ok, %{commands: [receive_request]}} =
             Client.exchange_relocation_receive(client, session, [])

    assert receive_request.id == source_id
    assert receive_request.descriptor == source_result.descriptor
    assert receive_request.source_endpoint == relocation.source_endpoint

    # The real worker polls this authenticated API. No pool is configured here,
    # so this control test must not claim a native receive or fabricate a receipt.
    receive_pid =
      start_supervised!(
        {Lilly.Transfer.ReceiveRuntime,
         config: %Lilly.Control.Config{
           client: Marshall.LillyControl.connect(%{client | base_url: worker_base}),
           state_dir: Path.join(context.tmp_dir, "control"),
           cgroup_path: "/sys/fs/cgroup/lilly.slice",
           pools: [],
           transfer_state_dir: context.tmp_dir
         },
         session: session,
         owner: self()}
      )

    assert_receive {:key_exchange_complete, 200}, 3000
    assert_receive {:key_exchange_complete, 200}, 3000

    assert {:ok, %{commands: []}} =
             Client.exchange_relocation_receive(foreign, foreign_session, [])

    receipt = Map.put(source_result, :dataset_guid, "300")

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_receive(foreign, foreign_session, [receipt])

    assert {:ok, %{commands: [], acknowledgements: [^source_id]}} =
             Client.exchange_relocation_receive(client, session, [receipt])

    assert {:ok, %{acknowledgements: [^source_id]}} =
             Client.exchange_relocation_receive(client, session, [receipt])

    assert {:error, :outcome_conflict} =
             Client.exchange_relocation_receive(client, session, [
               %{receipt | dataset_guid: "301"}
             ])

    # The single full receipt is the import prerequisite; an adoption result
    # before its lease is offered is not an import fact.
    {delta, final, final_receipt} = {source_request, source_result, receipt}

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_import(client, session, [receipt])

    assert {:ok, %{commands: [adoption]}} = Client.exchange_relocation_import(client, session, [])
    assert adoption.dataset_guid == "300" and adoption.descriptor == final.descriptor

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_import(foreign, foreign_session, [final_receipt])

    import_pid =
      start_supervised!(
        Supervisor.child_spec(
          {Lilly.Transfer.ReceiveRuntime,
           mode: :import,
           config: %Lilly.Control.Config{
             client: Marshall.LillyControl.connect(%{client | base_url: worker_base}),
             state_dir: Path.join(context.tmp_dir, "control"),
             cgroup_path: "/sys/fs/cgroup/lilly.slice",
             pools: [],
             transfer_state_dir: context.tmp_dir
           },
           session: session,
           owner: self()},
          id: :import_worker
        )
      )

    assert_receive {:key_exchange_complete, 200}, 3000

    assert {:ok, %{commands: [], acknowledgements: [imported_id]}} =
             Client.exchange_relocation_import(client, session, [final_receipt])

    assert imported_id == delta.id

    assert {:ok, :committed} = Marshall.Compute.RelocationCoordinator.advance(relocation.id)
    assert {:ok, %{commands: []}} = Client.exchange_relocation_readiness(client, session, [])

    assert {:ok, %{commands: [activation]}} =
             Client.exchange_execution(client, session, nil, [], [])

    assert activation.kind == :resume
    assert activation.checkpoint == checkpoint

    activated = %{
      event
      | id: Ash.UUID.generate(),
        placement_id: activation.placement_id,
        execution_epoch: activation.execution_epoch,
        generation: activation.generation,
        operation_id: activation.id,
        state: :running,
        compute_empty: false
    }

    assert {:ok, _} = Client.exchange_execution(client, session, nil, [], [activated])
    assert {:ok, %{commands: [probe]}} = Client.exchange_relocation_readiness(client, session, [])
    assert probe.id == activation.id and probe.generation == activation.generation

    ready = %{
      id: probe.id,
      descriptor: probe.descriptor,
      generation: probe.generation,
      boot_id: Ash.UUID.generate()
    }

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_readiness(foreign, foreign_session, [ready])

    readiness_pid =
      start_supervised!(
        Supervisor.child_spec(
          {Lilly.Transfer.ReceiveRuntime,
           mode: :readiness,
           config: %Lilly.Control.Config{
             client: Marshall.LillyControl.connect(%{client | base_url: worker_base}),
             state_dir: Path.join(context.tmp_dir, "control"),
             cgroup_path: "/sys/fs/cgroup/lilly.slice",
             pools: [],
             transfer_state_dir: context.tmp_dir
           },
           session: session,
           owner: self()},
          id: :readiness_worker
        )
      )

    assert_receive {:key_exchange_complete, 200}, 3000
    activation_id = activation.id

    assert {:ok, %{commands: [], acknowledgements: [^activation_id]}} =
             Client.exchange_relocation_readiness(client, session, [ready])

    assert {:ok, %{acknowledgements: [^activation_id]}} =
             Client.exchange_relocation_readiness(client, session, [ready])

    assert {:error, :outcome_conflict} =
             Client.exchange_relocation_readiness(client, session, [
               %{ready | boot_id: Ash.UUID.generate()}
             ])

    assert {:ok, :committed} = Marshall.Compute.RelocationCoordinator.advance(relocation.id)

    assert {:ok, %{commands: [cleanup]}} =
             Client.exchange_relocation_cleanup(foreign, foreign_session, [])

    cleanup_result = Map.drop(cleanup, [:expires_at])

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_cleanup(client, session, [cleanup_result])

    cleanup_pid =
      start_supervised!(
        Supervisor.child_spec(
          {Lilly.Transfer.ReceiveRuntime,
           mode: :cleanup,
           config: %Lilly.Control.Config{
             client: Marshall.LillyControl.connect(%{foreign | base_url: worker_base}),
             state_dir: Path.join(context.tmp_dir, "source-control"),
             cgroup_path: "/sys/fs/cgroup/lilly.slice",
             pools: [],
             transfer_state_dir: context.tmp_dir
           },
           session: foreign_session,
           owner: self()},
          id: :cleanup_worker
        )
      )

    assert_receive {:key_exchange_complete, 200}, 3000

    assert {:ok, %{acknowledgements: [_]}} =
             Client.exchange_relocation_cleanup(foreign, foreign_session, [cleanup_result])

    assert {:ok, :committed} = Marshall.Compute.RelocationCoordinator.advance(relocation.id)

    assert {:ok, %{commands: [source_delete]}} =
             Client.exchange_execution(foreign, foreign_session, nil, [], [])

    assert source_delete.kind == :delete and
             source_delete.placement_id == relocation.source_placement_id

    removed =
      Map.delete(
        %{
          event
          | id: Ash.UUID.generate(),
            operation_id: source_delete.id,
            generation: source_delete.generation,
            sequence: 3,
            state: :deleted,
            compute_empty: true,
            disk_present: false,
            cleanup_complete: true
        },
        :checkpoint
      )

    assert {:ok, %{outcome_acknowledgements: [_]}} =
             Client.exchange_execution(foreign, foreign_session, nil, [], [removed])

    assert {:ok, :committed} = Marshall.Compute.RelocationCoordinator.advance(relocation.id)

    assert {:ok, %{commands: [retirement]}} =
             Client.exchange_relocation_key_retirement(client, session, [])

    assert {:ok, retired} =
             Lilly.Transfer.KeyRuntime.retire(context.tmp_dir, destination.host.id, retirement)

    refute File.exists?(Path.join([context.tmp_dir, "transfers", relocation.id, "id_ed25519"]))

    assert {:error, _} =
             Lilly.Transfer.KeyRuntime.prepare(context.tmp_dir, destination.host.id, command)

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_key_retirement(foreign, foreign_session, [retired])

    assert {:ok, %{acknowledgements: [_]}} =
             Client.exchange_relocation_key_retirement(client, session, [retired])

    assert {:ok, %{acknowledgements: [_]}} =
             Client.exchange_relocation_key_retirement(client, session, [retired])

    assert {:ok, :committed} = Marshall.Compute.RelocationCoordinator.advance(relocation.id)
    assert {:ok, :finished} = Marshall.Compute.RelocationCoordinator.advance(relocation.id)

    assert {:ok, %{commands: []}} = Client.exchange_relocation_keys(foreign, foreign_session, [])

    assert {:error, :invalid_outcome} =
             Client.exchange_relocation_keys(foreign, foreign_session, [result])

    assert {:ok, _} = Client.open(foreign, Ash.UUID.generate())
    assert_receive {:transfer_cleanup_fenced, ^cleanup_pid, :stale_connection}, 5000
    stop_supervised!(:cleanup_worker)

    assert {:error, :stale_connection} =
             Client.exchange_relocation_cleanup(foreign, foreign_session, [cleanup_result])

    assert {:ok, _} = Client.open(client, Ash.UUID.generate())

    assert_receive {:transfer_receive_fenced, ^receive_pid, :stale_connection}, 5000
    stop_supervised!(Lilly.Transfer.ReceiveRuntime)
    assert_receive {:transfer_import_fenced, ^import_pid, :stale_connection}, 5000
    stop_supervised!(:import_worker)
    assert_receive {:transfer_readiness_fenced, ^readiness_pid, :stale_connection}, 5000
    stop_supervised!(:readiness_worker)

    assert {:error, :stale_connection} =
             Client.exchange_relocation_readiness(client, session, [ready])

    assert {:error, :stale_connection} =
             Client.exchange_relocation_receive(client, session, [receipt])

    assert {:error, :stale_connection} =
             Client.exchange_relocation_keys(client, session, [result])

    assert {:ok, :ok} = Credentials.revoke(destination.host.id)
    assert {:error, :unauthorized} = Client.exchange_relocation_receive(client, session, [])
    assert {:error, :unauthorized} = Client.exchange_relocation_keys(client, session, [])
    [vm] = Ledger.read!(VirtualMachine, id: context.vm.id)
    assert vm.current_placement_id == relocation.destination_placement_id
    assert vm.execution_epoch == relocation.destination_epoch

    assert [%{disk_held: false, compute_held: false, temporary_disk_bytes: 0}] =
             Ledger.read!(Marshall.Compute.Reservation,
               placement_id: relocation.source_placement_id
             )

    assert [%{disk_held: true}] =
             Ledger.read!(Marshall.Compute.Reservation,
               placement_id: relocation.destination_placement_id
             )
  end

  test "the v4 client exchanges executable commands and matching outcomes over verified HTTPS",
       context do
    base_url = listener(Marshall.AudiControl.FleetPlug, :https)

    {:ok, client} =
      client(context, base_url,
        cacertfile: @ca,
        protocol_version: 4,
        machine_id: context.host.machine_id
      )

    assert {:ok, session} = Client.open(client, Ash.UUID.generate())

    assert {:ok, %{commands: [command], outcome_acknowledgements: []}} =
             Client.exchange_execution(client, session, context.report, [], [])

    event = %{
      id: Ash.UUID.generate(),
      vm_id: command.vm_id,
      placement_id: command.placement_id,
      execution_epoch: command.execution_epoch,
      operation_id: command.id,
      generation: command.generation,
      sequence: 1,
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    assert {:ok, %{commands: [], outcome_acknowledgements: [id]}} =
             Client.exchange_execution(client, session, nil, [command.id], [event])

    assert id == event.id
    assert [%{status: :completed}] = Ledger.read!(Operation, id: command.id)

    assert {:ok, :ok} = Credentials.revoke(context.host.id)
    assert {:error, :unauthorized} = Client.exchange_execution(client, session, nil, [], [event])
  end

  test "v3 rejects outcome receipts that were never sent", context do
    id = Ash.UUID.generate()

    response = %{
      "version" => 4,
      "host_id" => context.host.id,
      "session_id" => id,
      "epoch" => 1,
      "commands" => [],
      "outcome_acknowledgements" => [Ash.UUID.generate()]
    }

    url = listener({Reply, {self(), 200, JSON.encode!(response), []}}, :http)

    {:ok, client} =
      client(context, url,
        allow_insecure_loopback: true,
        protocol_version: 4,
        machine_id: context.host.machine_id
      )

    assert {:error, :invalid_message} =
             Client.exchange_execution(
               client,
               %{session_id: id, epoch: 1, pools: []},
               nil,
               [],
               []
             )

    assert_receive {:control_request, "lilly.exchange"}
  end

  test "an untrusted certificate fails the actual TLS handshake", context do
    base_url = listener(Marshall.AudiControl.FleetPlug, :https)
    {:ok, client} = client(context, base_url)
    assert {:error, :transport_error} = Client.open(client, Ash.UUID.generate())
  end

  test "a redirected upgrade is refused without forwarding a credential", context do
    base_url = listener({Reply, {self(), 307, "", [{"location", "/credential-target"}]}}, :http)
    {:ok, client} = client(context, base_url, allow_insecure_loopback: true)
    assert {:error, :transport_error} = Client.open(client, Ash.UUID.generate())
    assert_receive {:http_request, "/api/control/v1"}
    refute_received {:http_request, "/credential-target"}
  end

  test "response limits apply to documents and refused upgrades", context do
    oversized = %{"version" => 3, "padding" => :binary.copy(" ", OverallsProtocol.max_body())}
    base_url = listener({Reply, {self(), 200, JSON.encode!(oversized), []}}, :http)
    {:ok, client} = client(context, base_url, allow_insecure_loopback: true)
    assert {:error, :message_too_large} = Client.open(client, Ash.UUID.generate())

    base_url =
      listener(
        {Reply, {self(), 500, :binary.copy(" ", OverallsProtocol.max_body() + 1), []}},
        :http
      )

    {:ok, client} = client(context, base_url, allow_insecure_loopback: true)
    assert {:error, :transport_error} = Client.open(client, Ash.UUID.generate())
  end

  test "a reply that is not a JSON document never opens a session", context do
    body = :zlib.gzip(:binary.copy(" ", OverallsProtocol.max_body() * 2))
    base_url = listener({Reply, {self(), 200, body, [{"content-encoding", "gzip"}]}}, :http)
    {:ok, client} = client(context, base_url, allow_insecure_loopback: true)
    assert {:error, reason} = Client.open(client, Ash.UUID.generate())
    assert reason in [:http_error, :invalid_message]
  end

  test "key client rejects uncorrelated and open-schema responses", context do
    session = %{session_id: Ash.UUID.generate(), epoch: 1, pools: []}

    valid = %{
      "version" => 4,
      "host_id" => context.host.id,
      "session_id" => session.session_id,
      "epoch" => 1,
      "commands" => [],
      "acknowledgements" => []
    }

    command = %{
      "id" => Ash.UUID.generate(),
      "host_id" => Ash.UUID.generate(),
      "placement_id" => Ash.UUID.generate(),
      "source_host_id" => context.host.id,
      "execution_epoch" => 2,
      "source_endpoint" => context.host.transfer_endpoint
    }

    for response <- [
          Map.put(valid, "host_id", Ash.UUID.generate()),
          Map.put(valid, "session_id", Ash.UUID.generate()),
          Map.put(valid, "epoch", 2),
          Map.put(valid, "version", 2),
          Map.put(valid, "private_key", "forbidden"),
          Map.put(valid, "acknowledgements", [Ash.UUID.generate()]),
          Map.put(valid, "commands", [command])
        ] do
      url = listener({Reply, {self(), 200, JSON.encode!(response), []}}, :https)
      {:ok, client} = client(context, url, cacertfile: @ca)
      assert {:error, :invalid_message} = Client.exchange_relocation_keys(client, session, [])

      assert {:error, :invalid_message} =
               Client.exchange_relocation_snapshot_cleanup(client, session, [])

      assert {:error, :invalid_message} =
               Client.exchange_relocation_destination_revocation(client, session, [])

      assert {:error, :invalid_message} =
               Client.exchange_relocation_destination_cleanup(client, session, [])
    end
  end

  defp client(context, url, options \\ []) do
    with {:ok, client} <-
           Client.new(
             url,
             context.host.id,
             context.credential.token,
             Keyword.put_new(options, :machine_id, context.host.machine_id)
           ),
         do: {:ok, Marshall.LillyControl.connect(client)}
  end

  defp listener(plug, scheme) do
    tls = if scheme == :https, do: [certfile: @certificate, keyfile: @key], else: []

    server =
      start_supervised!(
        {Bandit,
         [plug: plug, scheme: scheme, ip: {127, 0, 0, 1}, port: 0, startup_log: false] ++ tls},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "#{scheme}://127.0.0.1:#{port}"
  end

  test "host stream is fenced when the published location changes", context do
    alias OverallsProtocol.Terminal
    alias Marshall.Test.WebSocketClient, as: Websocket
    alias Marshall.Terminal.{Directory, Remote}
    base_url = listener(MarshallWeb.FleetEndpoint, :https)
    previous_url = Application.get_env(:marshall, :terminal_peer_url)
    previous_ca = Application.get_env(:marshall, :terminal_peer_ca)
    Application.put_env(:marshall, :terminal_peer_url, base_url)
    Application.put_env(:marshall, :terminal_peer_ca, @ca)

    on_exit(fn ->
      Application.put_env(:marshall, :terminal_peer_url, previous_url)
      Application.put_env(:marshall, :terminal_peer_ca, previous_ca)
    end)

    {:ok, client} = client(context, base_url, cacertfile: @ca)
    {:ok, session} = Client.open(client, Ash.UUID.generate())

    {:ok, host_socket} =
      Websocket.open(base_url, "/api/provisioners/v4/stream",
        headers: [{"authorization", "Lilly " <> client.token}],
        cacertfile: @ca
      )

    :ok =
      Websocket.send_binary(
        host_socket,
        Terminal.encode_control_frame(%{
          type: :hello,
          host_id: context.host.id,
          session_id: session.session_id,
          epoch: session.epoch
        })
      )

    assert {:ok, {:binary, _hello}} = Websocket.recv(host_socket, 5000)
    assert {:ok, location} = Directory.lookup(context.host.id)
    {:ok, remote} = Remote.start(self(), location)

    old_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :host_id]], fn ->
        :ok = Directory.publish(context.host.id, Ash.UUID.generate())

        Process.send_after(remote, :check_location, 10)
        ref = Process.monitor(remote)
        assert_receive {:DOWN, ^ref, :process, ^remote, :normal}, 5000
      end)

    assert logs =~ "event=terminal.stream_fenced"
    assert logs =~ context.host.id
  end
end
