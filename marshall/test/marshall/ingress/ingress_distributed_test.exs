defmodule Marshall.Ingress.DistributedTest do
  use ExUnit.Case, async: false
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.WebStream
  alias Marshall.IngressHistoryFixture, as: Fx
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] ingress-three-independent-peers
  # All schedules MUST use three distinct BEAM nodes with independent Repo pools;
  # the coordinating node MUST NOT count as one of the three instances.
  setup_all do
    peers =
      Enum.map(
        [
          :marshall_ingress_distributed_1,
          :marshall_ingress_distributed_2,
          :marshall_ingress_distributed_3
        ],
        fn name ->
          peer =
            start_supervised!(%{
              id: name,
              start:
                {:peer, :start_link,
                 [
                   %{
                     name: String.to_atom("#{name}_#{System.pid()}"),
                     connection: :standard_io,
                     args: [~c"+S", ~c"2:2", ~c"+SDcpu", ~c"1", ~c"+SDio", ~c"1"],
                     wait_boot: 30_000
                   }
                 ]},
              restart: :temporary
            })

          node = :peer.call(peer, :erlang, :node, [])
          :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])

          config =
            for {app, _, _} <- Application.loaded_applications(),
                app not in [:kernel, :stdlib, :elixir, :logger],
                do: {app, Application.get_all_env(app)}

          :ok = :peer.call(peer, Application, :put_all_env, [config, [persistent: true]])

          repo_config =
            Application.fetch_env!(:marshall, Repo)
            |> Keyword.put(:pool, DBConnection.ConnectionPool)
            |> Keyword.put(:pool_size, 4)

          :ok =
            :peer.call(peer, Application, :put_env, [
              :marshall,
              Repo,
              repo_config,
              [persistent: true]
            ])

          :ok =
            :peer.call(peer, Application, :put_env, [:logger, :level, :error, [persistent: true]])

          {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:marshall], 30_000)
          {peer, node}
        end
      )

    assert length(Enum.uniq(Enum.map(peers, &elem(&1, 1)))) == 3
    %{peers: Enum.map(peers, &elem(&1, 0))}
  end

  # @cc [owner:ghuntley,label:verification;concurrency] ingress-distributed-rotation-oracle
  # A rotation held mid-transaction MUST leave the committed generation readable
  # on every peer, and a renewal/close queued behind it MUST refuse with the old
  # generation instead of reviving authority. Concurrent configure and expiry
  # complete with exact documented outcomes; every peer's durable view agrees.
  test "concurrent renew, configure, close and expiry serialize with rotation", %{
    peers: [renewer, rotator, observer] = peers
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      fixture = Fx.new_public()
      refresher = spawn_report_loop(observer, fixture)
      gate = System.unique_integer([:positive])
      Fx.install_rotation_gate(fixture.service.id, gate)
      Fx.query("SELECT pg_advisory_lock($1)", [gate])

      try do
        {:ok, first} = :peer.call(renewer, Fx, :open_web, [fixture, nil, 0], 30_000)
        {:ok, second} = :peer.call(observer, Fx, :open_web, [fixture, nil, 0], 30_000)
        initial = fixture.service.generation

        rotation =
          Task.Supervisor.async_nolink(supervisor, fn ->
            :peer.call(rotator, Fx, :rotate, [fixture], 30_000)
          end)

        await_fn(fn -> gate_waiting?(gate) end, "Rotation did not reach the update gate")

        # While rotation holds the service row, every peer still reads the
        # committed pre-rotation generation.
        for peer <- peers do
          assert :peer.call(peer, Fx, :service_generation, [fixture]) == initial
        end

        # A concurrent visibility policy round-trip takes only the VM lock and
        # completes underneath the held generation change.
        assert {:ok, changed} =
                 :peer.call(observer, Fx, :configure_endpoint, [fixture, 8080, :private], 30_000)

        assert changed.policy_revision == fixture.endpoint.policy_revision + 1

        assert {:ok, restored} =
                 :peer.call(renewer, Fx, :configure_endpoint, [fixture, 8080, :public], 30_000)

        assert restored.policy_revision == changed.policy_revision + 1

        renewal =
          Task.Supervisor.async_nolink(supervisor, fn ->
            :peer.call(renewer, Fx, :renew_web, [fixture, first.ticket], 30_000)
          end)

        stale_close =
          Task.Supervisor.async_nolink(supervisor, fn ->
            :peer.call(rotator, Fx, :close, [fixture, :web, second.ticket], 30_000)
          end)

        # Both old-credential calls MUST remain queued behind the held rotation.
        assert Task.yield(renewal, 500) == nil
        assert Task.yield(stale_close, 500) == nil

        # A synthetic expiry fault lands mid-schedule without touching history.
        :ok =
          :peer.call(
            observer,
            Fx,
            :expire_stream,
            [second.binding.session_id, DateTime.utc_now(), :web],
            30_000
          )

        Fx.query("SELECT pg_advisory_unlock($1)", [gate])
        rotated = Task.await(rotation, 30_000)
        assert rotated.service.generation == initial + 1

        assert Fx.reason(Task.await(renewal, 30_000)) == :unauthorized
        assert Fx.reason(Task.await(stale_close, 30_000)) == :unauthorized

        # The rotated credential MUST NOT close old-generation streams either:
        # fenced authority expires, it is never revoked through the new token.
        assert Fx.reason(:peer.call(rotator, Fx, :close, [rotated, :web, first.ticket], 30_000)) ==
                 :unauthorized

        # Post-rotation admission on one peer binds the new generation, renews
        # from a second peer and closes from a third.
        {:ok, fresh} = :peer.call(renewer, Fx, :open_web, [rotated, nil, 0], 30_000)

        assert {:ok, renewed} =
                 :peer.call(observer, Fx, :renew_web, [rotated, fresh.ticket], 30_000)

        assert renewed.binding == fresh.binding

        assert {:ok, %{closed: true}} =
                 :peer.call(rotator, Fx, :close, [rotated, :web, fresh.ticket], 30_000)

        for peer <- peers do
          assert :peer.call(peer, Fx, :service_generation, [fixture]) == initial + 1
          rows = :peer.call(peer, Fx, :stream_rows, [fixture.service.id])
          assert length(rows) == 3

          assert Enum.sort(Enum.map(rows, & &1.service_generation)) == [
                   initial,
                   initial,
                   initial + 1
                 ]

          [fresh_row] = Enum.filter(rows, &(&1.id == fresh.binding.session_id))
          assert fresh_row.service_generation == initial + 1
          assert fresh_row.closed_at != nil
        end

        # Fenced streams kept no renewal history; only the fresh stream closed.
        for {id, expected} <- [
              {first.binding.session_id, [:record]},
              {second.binding.session_id, [:record]},
              {fresh.binding.session_id, [:close, :record]}
            ] do
          assert actions(id) == expected
        end
      after
        send(refresher, :stop)

        try do
          Fx.query("SELECT pg_advisory_unlock($1)", [gate])
        after
          Fx.remove_rotation_gate(fixture.service.id)
        end

        Fx.cleanup_public(fixture)
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] ingress-distributed-live-report
  # Host evidence MUST be refreshed on a peer through the real ingestion path
  # for the whole schedule, never by backdating or by pausing freshness checks.
  @spec spawn_report_loop(pid(), map()) :: pid()
  defp spawn_report_loop(peer, fixture) do
    spawn(fn -> report_loop(peer, fixture, 10) end)
  end

  @spec report_loop(pid(), map(), non_neg_integer()) :: :ok
  defp report_loop(peer, fixture, sequence) do
    receive do
      :stop -> :ok
    after
      400 ->
        :ok = :peer.call(peer, Fx, :fresh_report, [fixture, sequence], 30_000)
        report_loop(peer, fixture, sequence + 10)
    end
  end

  @spec gate_waiting?(pos_integer()) :: boolean()
  defp gate_waiting?(gate),
    do:
      Fx.query(
        "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=$1 AND NOT granted",
        [gate]
      ).rows == [[1]]

  @spec await_fn((-> boolean()), String.t(), non_neg_integer()) :: :ok
  defp await_fn(probe, message, attempts \\ 150)
  defp await_fn(_probe, message, 0), do: flunk(message)

  defp await_fn(probe, message, attempts) do
    if probe.() do
      :ok
    else
      receive do
      after
        20 -> await_fn(probe, message, attempts - 1)
      end
    end
  end

  @spec actions(String.t()) :: [atom()]
  defp actions(id),
    do:
      WebStream.Version
      |> Ledger.read!(version_source_id: id)
      |> Enum.map(& &1.version_action_name)
      |> Enum.sort()
end
