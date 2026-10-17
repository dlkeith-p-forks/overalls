defmodule Audi.DNS.ReplicaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise
  alias Audi.Control.Client
  alias Audi.DNS.{Authority, Directory, Replica, Server, Snapshot, Wire}
  @fixtures Path.expand("../../marshall/test/fixtures/tls", __DIR__)
  @label "demo-0123456789abcdef0123456789abcdef"
  @zone "apps.example"
  @token "audi_service_" <> String.duplicate("A", 43)

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: {Audi.Test.DNSControl, owner: self()},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, client} =
      Client.new("https://127.0.0.1:#{port}", @token, :dns,
        cacertfile: Path.join(@fixtures, "ca.pem")
      )

    client = Audi.Test.DNSControl.connected(client)

    directory = Audi.Test.DNSDirectory.start!([])

    authority = %Authority{
      zone: String.split(@zone, "."),
      nameservers: [["ns", "example"]],
      mailbox: ["hostmaster", "example"],
      directory: directory
    }

    dns = start_supervised!({Server, authority: authority})
    %{client: client, directory: directory, port: Server.port(dns)}
  end

  # @cc [owner:ghuntley,label:verification;protocol] audi-version-refusal-transport
  # Explicit 426 MUST preserve its terminal class before payload-size or JSON
  # classification over real verified HTTPS, including configured-limit families.
  property "verified TLS version refusal precedes malformed and oversized payloads", c do
    check all(generated <- member_of([0, 4095, 4096, 4097, 8_388_608, 8_388_609]), max_runs: 2) do
      for size <- Enum.uniq([0, 4095, 4096, 4097, 8_388_608, 8_388_609, generated]),
          operation <- [:dns, :identity] do
        server_id = make_ref()

        server =
          start_supervised!(
            {Bandit,
             plug:
               {Audi.Test.DNSControl, owner: self(), upgrade_refusal: String.duplicate("x", size)},
             scheme: :https,
             ip: {127, 0, 0, 1},
             port: 0,
             startup_log: false,
             certfile: Path.join(@fixtures, "localhost.pem"),
             keyfile: Path.join(@fixtures, "localhost.key")},
            id: server_id
          )

        {:ok, {_, port}} = ThousandIsland.listener_info(server)
        client = Audi.Test.DNSControl.started(%{c.client | origin: "https://127.0.0.1:#{port}"})

        try do
          assert_receive {:control_upgrade_refused, ^size}, 1_000
          assert await_version_stop(client.control, System.monotonic_time(:millisecond) + 5_000)

          task =
            Task.async(fn ->
              case operation do
                :dns -> Client.dns_snapshot(client, @zone)
                :identity -> Client.identity(client)
              end
            end)

          assert Task.await(task, 10_000) == {:error, :unsupported_version}

          assert OverallsProtocol.Control.Client.status(client.control) ==
                   {:disconnected, :unsupported_version}

          refute_receive {:control_request, _, _, _, _, _}, 0
        after
          stop_supervised(client.control)
          stop_supervised(server_id)
        end
      end
    end
  end

  @spec await_version_stop(GenServer.server(), integer()) :: boolean()
  defp await_version_stop(control, deadline) do
    case OverallsProtocol.Control.Client.status(control) do
      {:disconnected, :unsupported_version} ->
        true

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          receive do
          after
            1 -> await_version_stop(control, deadline)
          end
        end
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] audi-pending-close-terminal-class
  # Actual close4001 MUST preserve the permanent class for every already
  # dispatched read and later request. Prior transient replies MUST remain
  # transient, as MUST actual close4008 loss; the oracle MUST observe both
  # peer requests before closing.
  @tag :actual_version_close
  property "pending reads retain terminal version refusal over the actual TLS socket", c do
    check all(prefix <- member_of([0, 1, 2]), max_runs: 3) do
      for {close_reason, expected} <- [
            {:idle, :transport_error},
            {:unsupported_version, :unsupported_version}
          ] do
        client = Audi.Test.DNSControl.connected(c.client)

        try do
          for _ <- List.duplicate(:transient, prefix) do
            task = Task.async(fn -> Client.identity(client) end)

            assert_receive {:control_request, worker, reference, "/api/audi/v1/identity", _, _},
                           1000

            send(worker, {reference, 503, "{}"})
            assert Task.await(task, 5000) == {:error, :http_error}
          end

          tasks =
            for operation <- [:dns, :identity] do
              Task.async(fn ->
                case operation do
                  :dns -> Client.dns_snapshot(client, @zone)
                  :identity -> Client.identity(client)
                end
              end)
            end

          requests =
            for _ <- 1..2 do
              assert_receive {:control_request, worker, reference, path, _, _}, 1000
              {worker, reference, path}
            end

          assert MapSet.new(Enum.map(requests, &elem(&1, 2))) ==
                   MapSet.new(["/api/audi/v1/dns-snapshot", "/api/audi/v1/identity"])

          [{worker, reference, _} | _] = requests

          send(
            worker,
            {reference, :close, OverallsProtocol.Control.Close.code(close_reason)}
          )

          for task <- tasks,
              do: assert(Task.await(task, 5000) == {:error, expected})

          if close_reason == :unsupported_version do
            assert OverallsProtocol.Control.Client.status(client.control) ==
                     {:disconnected, :unsupported_version}

            assert Client.identity(client) == {:error, :unsupported_version}
            assert Client.dns_snapshot(client, @zone) == {:error, :unsupported_version}
          end

          refute_receive {:control_request, _, _, _, _, _}, 100
        after
          stop_supervised(client.control)
        end
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] audi-dns-pending-close-cadence
  # Actual close4001 during refresh MUST halt the worker before any retry while
  # retaining published bytes and their original expiry. Stale timer delivery
  # MUST NOT revive it; independent UDP/TCP queries MUST lose expired authority.
  @tag timeout: 120_000
  @tag :actual_version_close
  property "DNS cadence stops on a pending socket version close without renewing authority", c do
    check all(generated <- member_of([0, 1, 2]), max_runs: 2) do
      for transients <- Enum.uniq([0, 1, 2, generated]) do
        client = Audi.Test.DNSControl.connected(c.client)

        replica =
          start_supervised!({Replica, client: client, directory: c.directory, zone: @zone})

        try do
          revision = System.unique_integer([:positive, :monotonic])
          reply(200, snapshot(revision))
          _ = :sys.get_state(replica)
          published = :sys.get_state(c.directory)

          for _ <- List.duplicate(:transient, transients) do
            state = :sys.get_state(replica)
            send(replica, {:refresh, state.timer})
            reply(503, %{})
            _ = :sys.get_state(replica)
            assert Replica.automatic_work_enabled?(replica)
            assert :sys.get_state(c.directory) == published
          end

          prior = :sys.get_state(replica)
          send(replica, {:refresh, prior.timer})

          assert_receive {:control_request, worker, reference, "/api/audi/v1/dns-snapshot", _, _},
                         1000

          send(
            worker,
            {reference, :close, OverallsProtocol.Control.Close.code(:unsupported_version)}
          )

          refute Replica.automatic_work_enabled?(replica)
          assert :sys.get_state(c.directory) == published

          for timer <- [prior.timer, make_ref()], do: send(replica, {:refresh, timer})
          refute Replica.automatic_work_enabled?(replica)
          refute_receive {:control_request, _, _, _, _, _}, 1100
          assert answer(c.port, @label <> "." <> @zone, 1, :udp) == {0, 1}

          Process.sleep(max(published.expires_at - System.monotonic_time(:millisecond) + 1, 0))
          assert answer(c.port, @label <> "." <> @zone, 1, :tcp) == {2, 0}
          assert :sys.get_state(c.directory) == published
          refute_receive {:control_request, _, _, _, _, _}, 100
        after
          stop_supervised(Replica)
          stop_supervised(client.control)
        end
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] audi-dns-terminal-version-history
  # Transient failures may retry; an explicit 426 MUST halt automatic and stale
  # timer refreshes while preserving exact published bytes and original expiry.
  property "DNS replica halts after version refusal without extending published authority", c do
    check all(transients <- member_of([0, 1, 2]), max_runs: 3) do
      replica =
        start_supervised!({Replica, client: c.client, directory: c.directory, zone: @zone})

      try do
        revision = System.unique_integer([:positive, :monotonic])
        reply(200, snapshot(revision))
        _ = :sys.get_state(replica)
        published = :sys.get_state(c.directory)

        for _ <- List.duplicate(:transient, transients) do
          state = :sys.get_state(replica)
          send(replica, {:refresh, state.timer})
          reply(503, %{})
          _ = :sys.get_state(replica)
          assert :sys.get_state(c.directory) == published
        end

        prior = :sys.get_state(replica)
        send(replica, {:refresh, prior.timer})
        reply(426, %{})
        halted = :sys.get_state(replica)
        assert :sys.get_state(c.directory) == published

        for timer <- [prior.timer, halted.timer, make_ref()] do
          send(replica, {:refresh, timer})
        end

        _ = :sys.get_state(replica)
        refute_receive {:control_request, _, _, _, _, _}, 1100
        assert Map.get(:sys.get_state(replica), :halted?) == true
        refute Replica.automatic_work_enabled?(replica)
        assert :sys.get_state(c.directory) == published
        assert answer(c.port, @label <> "." <> @zone, 1, :udp) == {0, 1}
        Process.sleep(max(published.expires_at - System.monotonic_time(:millisecond) + 1, 0))
        assert answer(c.port, @label <> "." <> @zone, 1, :tcp) == {2, 0}
        refute_receive {:control_request, _, _, _, _, _}, 100
        assert :sys.get_state(c.directory) == published
      after
        stop_supervised(Replica)
      end
    end
  end

  test "background HTTPS refresh drives real UDP/TCP answers, preserves data on failure and removes it on a newer snapshot",
       c do
    replica = start_supervised!({Replica, client: c.client, directory: c.directory, zone: @zone})
    assert answer(c.port, @label <> "." <> @zone, 1, :udp) == {2, 0}
    reply(200, snapshot(1))
    _ = :sys.get_state(replica)

    for transport <- [:udp, :tcp] do
      assert answer(c.port, @label <> "." <> @zone, 1, transport) == {0, 1}
      assert answer(c.port, "p3000-" <> @label <> "." <> @zone, 1, transport) == {0, 1}
      assert answer(c.port, "_acme-challenge." <> @label <> "." <> @zone, 16, transport) == {0, 1}
    end

    assert {:ok, 1, before} = Directory.lookup(c.directory, @label <> "." <> @zone)
    refute inspect(:sys.get_status(replica)) =~ @token

    reply(503, %{"private" => "unavailable"})
    _ = :sys.get_state(replica)
    assert {:ok, 1, ^before} = Directory.lookup(c.directory, @label <> "." <> @zone)

    reply(200, Map.put(snapshot(2), "zone", "wrong.example"))
    _ = :sys.get_state(replica)
    assert {:ok, 1, ^before} = Directory.lookup(c.directory, @label <> "." <> @zone)

    reply(200, snapshot(3) |> Map.merge(%{"routes" => [], "proofs" => []}))
    _ = :sys.get_state(replica)
    assert answer(c.port, @label <> "." <> @zone, 1, :udp) == {3, 0}
    assert answer(c.port, "_acme-challenge." <> @label <> "." <> @zone, 16, :tcp) == {3, 0}
  end

  test "a burst of zone hints refreshes once at once and halted replicas ignore hints", c do
    replica = start_supervised!({Replica, client: c.client, directory: c.directory, zone: @zone})
    reply(200, snapshot(1))
    _ = :sys.get_state(replica)
    :ok = :sys.suspend(replica)
    for _ <- 1..3, do: send(replica, {:control_hint, "dns_snapshot", "vm"})
    :ok = :sys.resume(replica)
    assert_receive {:control_request, pid, ref, "/api/audi/v1/dns-snapshot", _, _}, 500
    send(pid, {ref, 200, JSON.encode!(snapshot(2))})
    _ = :sys.get_state(replica)
    assert {:ok, 2, _} = Directory.lookup(c.directory, @label <> "." <> @zone)
    refute_receive {:control_request, _, _, _, _, _}, 300

    state = :sys.get_state(replica)
    send(replica, {:refresh, state.timer})
    reply(426, %{})
    _ = :sys.get_state(replica)
    send(replica, {:control_hint, "dns_snapshot", "vm"})
    refute_receive {:control_request, _, _, _, _, _}, 1100
  end

  test "expired replica serves SERVFAIL during outage and a later successful refresh recovers",
       c do
    replica = start_supervised!({Replica, client: c.client, directory: c.directory, zone: @zone})
    value = snapshot(1) |> Map.merge(%{"ttl" => 500, "routes" => [], "proofs" => []})
    reply(200, value)
    _ = :sys.get_state(replica)
    assert answer(c.port, @label <> "." <> @zone, 1, :udp) == {3, 0}
    reply(401, %{})
    _ = :sys.get_state(replica)
    assert answer(c.port, @label <> "." <> @zone, 1, :udp) == {2, 0}
    reply(200, snapshot(2))
    _ = :sys.get_state(replica)
    assert answer(c.port, @label <> "." <> @zone, 1, :tcp) == {0, 1}
  end

  test "nested child wildcard proof reaches authoritative DNS without an address", c do
    replica = start_supervised!({Replica, client: c.client, directory: c.directory, zone: @zone})
    environment = "dev-" <> String.duplicate("1", 32)
    label = "apps." <> environment <> ".inception"
    proof = Base.url_encode64(<<0::256>>, padding: false)

    value =
      snapshot(1)
      |> Map.put("routes", [])
      |> Map.put("proofs", [
        %{"label" => label, "proofs" => [proof], "ttl" => 5000}
      ])

    reply(200, value)
    _ = :sys.get_state(replica)

    for transport <- [:udp, :tcp] do
      assert answer(c.port, "_acme-challenge." <> label <> "." <> @zone, 16, transport) ==
               {0, 1}
    end

    assert answer(c.port, label <> "." <> @zone, 1, :tcp) == {0, 0}
  end

  # @cc [owner:ghuntley,label:verification;security] dns-wire-snapshot-history
  # Generated accepted, stale and invalid publications MUST keep actual UDP and
  # TCP answers aligned with the latest accepted live route and proof inventory.
  property "UDP and TCP answers follow only the latest accepted snapshot", c do
    check all(
            actions <-
              shuffle([
                :both,
                :route,
                :proof,
                :empty,
                :expired_route,
                :stale,
                :conflict,
                :expired_snapshot,
                :invalid
              ]),
            max_runs: 12
          ) do
      revision = System.unique_integer([:positive, :monotonic])
      {:ok, initial} = Snapshot.decode(snapshot(revision), @zone, monotonic_now())
      assert :ok = Directory.publish(c.directory, revision, initial.entries, initial.expires_at)
      assert_answers(c.port, :both)

      Enum.reduce(actions, {revision, :both}, fn action, {current_revision, current_state} ->
        case action do
          :stale ->
            old = snapshot(current_revision - 1) |> Map.merge(%{"routes" => [], "proofs" => []})
            {:ok, decoded} = Snapshot.decode(old, @zone, monotonic_now())

            assert {:error, :stale} =
                     Directory.publish(
                       c.directory,
                       decoded.revision,
                       decoded.entries,
                       decoded.expires_at
                     )

            assert_answers(c.port, current_state)
            {current_revision, current_state}

          :invalid ->
            assert {:error, :invalid_message} =
                     snapshot(current_revision + 1)
                     |> Map.put("zone", "wrong.example")
                     |> Snapshot.decode(@zone, monotonic_now())

            assert_answers(c.port, current_state)
            {current_revision, current_state}

          :conflict ->
            changed =
              snapshot(current_revision)
              |> put_in(["routes", Access.at(0), "addresses"], ["192.0.2.2"])

            {:ok, decoded} = Snapshot.decode(changed, @zone, monotonic_now())

            assert {:error, :conflict} =
                     Directory.publish(
                       c.directory,
                       decoded.revision,
                       decoded.entries,
                       decoded.expires_at
                     )

            assert_answers(c.port, current_state)
            {current_revision, current_state}

          :expired_snapshot ->
            next_revision = System.unique_integer([:positive, :monotonic])
            {:ok, decoded} = Snapshot.decode(snapshot(next_revision), @zone, monotonic_now())

            assert {:error, :stale} =
                     Directory.publish(
                       c.directory,
                       decoded.revision,
                       decoded.entries,
                       monotonic_now() - 1
                     )

            assert_answers(c.port, current_state)
            {current_revision, current_state}

          next_state ->
            next_revision = System.unique_integer([:positive, :monotonic])

            value =
              case next_state do
                :both ->
                  snapshot(next_revision)

                :route ->
                  Map.put(snapshot(next_revision), "proofs", [])

                :proof ->
                  Map.put(snapshot(next_revision), "routes", [])

                :empty ->
                  Map.merge(snapshot(next_revision), %{"routes" => [], "proofs" => []})

                :expired_route ->
                  put_in(snapshot(next_revision), ["routes", Access.at(0), "ttl"], 1)
              end

            started =
              if next_state == :expired_route, do: monotonic_now() - 10, else: monotonic_now()

            {:ok, decoded} = Snapshot.decode(value, @zone, started)

            assert :ok =
                     Directory.publish(
                       c.directory,
                       decoded.revision,
                       decoded.entries,
                       decoded.expires_at
                     )

            assert_answers(c.port, next_state)
            {next_revision, next_state}
        end
      end)
    end
  end

  @spec assert_answers(:inet.port_number(), :both | :route | :proof | :empty | :expired_route) ::
          :ok
  defp assert_answers(port, state) do
    expected_address =
      case state do
        :both -> {0, 1}
        :route -> {0, 1}
        :proof -> {0, 0}
        :empty -> {3, 0}
        :expired_route -> {2, 0}
      end

    expected_proof = if state in [:both, :proof, :expired_route], do: {0, 1}, else: {3, 0}

    for transport <- [:udp, :tcp] do
      assert answer(port, @label <> "." <> @zone, 1, transport) == expected_address

      {address_code, address_count, address_authoritative, addresses} =
        answer_data(port, @label <> "." <> @zone, 1, transport)

      assert {address_code, address_count} == expected_address
      assert address_authoritative == (state != :expired_route)
      assert addresses == if(state in [:both, :route], do: [<<192, 0, 2, 1>>], else: [])

      assert answer(port, "_acme-challenge." <> @label <> "." <> @zone, 16, transport) ==
               expected_proof

      {proof_code, proof_count, proof_authoritative, proofs} =
        answer_data(port, "_acme-challenge." <> @label <> "." <> @zone, 16, transport)

      assert {proof_code, proof_count} == expected_proof
      assert proof_authoritative
      proof = Base.url_encode64(<<0::256>>, padding: false)

      assert proofs ==
               if(state in [:both, :proof, :expired_route], do: [<<43, proof::binary>>], else: [])
    end

    :ok
  end

  @spec monotonic_now() :: integer()
  defp monotonic_now, do: System.monotonic_time(:millisecond)

  defp reply(status, body) do
    assert_receive {:control_request, pid, ref, "/api/audi/v1/dns-snapshot", [authorization],
                    %{"version" => 1, "zone" => @zone}},
                   4000

    assert authorization == "Bearer " <> @token
    send(pid, {ref, status, JSON.encode!(body)})
  end

  test "snapshot transport keeps role, response-size and malformed-document boundaries", c do
    assert {:error, :binding_mismatch} = Client.dns_snapshot(%{c.client | role: :gateway}, @zone)
    tasks = start_supervised!({Task.Supervisor, []})

    for {body, expected} <- [
          {JSON.encode!(%{"version" => 1, "padding" => String.duplicate("x", 8_388_609)}),
           :message_too_large},
          {JSON.encode!(%{"version" => 1, "zone" => "private"}), :invalid_message}
        ] do
      task = Task.Supervisor.async_nolink(tasks, fn -> Client.dns_snapshot(c.client, @zone) end)
      assert_receive {:control_request, pid, ref, "/api/audi/v1/dns-snapshot", _, _}, 4000
      send(pid, {ref, 200, body})
      assert {:error, ^expected} = Task.await(task, 5000)
    end
  end

  defp snapshot(revision) do
    %{
      "version" => 1,
      "zone" => @zone,
      "revision" => revision,
      "ttl" => 5000,
      "routes" => [%{"label" => @label, "addresses" => ["192.0.2.1"], "ttl" => 5000}],
      "proofs" => [
        %{
          "label" => @label,
          "proofs" => [Base.url_encode64(<<0::256>>, padding: false)],
          "ttl" => 5000
        }
      ]
    }
  end

  @spec answer_data(:inet.port_number(), binary(), non_neg_integer(), :udp | :tcp) ::
          {non_neg_integer(), non_neg_integer(), boolean(), [binary()]}
  defp answer_data(port, name, type, transport) do
    response = response(port, name, type, transport)

    <<42::16, flags::16, 1::16, count::16, _authority::16, _additional::16, body::binary>> =
      response

    owner_size = byte_size(Wire.encode_name(String.split(name, ".")))
    question_size = owner_size + 4
    <<_question::binary-size(^question_size), records::binary>> = body

    answers =
      case count do
        0 ->
          []

        1 ->
          <<_owner::binary-size(^owner_size), ^type::16, 1::16, _ttl::32, size::16,
            data::binary-size(size), _::binary>> = records

          [data]
      end

    {flags &&& 15, count, (flags &&& 0x0400) != 0, answers}
  end

  @spec answer(:inet.port_number(), binary(), non_neg_integer(), :udp | :tcp) ::
          {non_neg_integer(), non_neg_integer()}
  defp answer(port, name, type, transport) do
    <<42::16, flags::16, 1::16, count::16, _::binary>> = response(port, name, type, transport)
    {flags &&& 15, count}
  end

  @spec response(:inet.port_number(), binary(), non_neg_integer(), :udp | :tcp) :: binary()
  defp response(port, name, type, transport) do
    packet =
      <<42::16, 0x0100::16, 1::16, 0::16, 0::16, 0::16>> <>
        Wire.encode_name(String.split(name, ".")) <> <<type::16, 1::16>>

    response =
      case transport do
        :udp ->
          {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

          try do
            :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, packet)
            {:ok, {_, _, response}} = :gen_udp.recv(socket, 0, 1000)
            response
          after
            :gen_udp.close(socket)
          end

        :tcp ->
          {:ok, socket} =
            :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: 2])

          try do
            :ok = :gen_tcp.send(socket, packet)
            {:ok, response} = :gen_tcp.recv(socket, 0, 1000)
            response
          after
            :gen_tcp.close(socket)
          end
      end

    response
  end
end
