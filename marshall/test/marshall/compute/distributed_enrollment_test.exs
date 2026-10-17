defmodule Marshall.Compute.DistributedEnrollmentTest do
  @moduledoc "Three-BEAM enrollment/credential races against committed PostgreSQL state."
  use ExUnit.Case, async: false
  alias Marshall.CommittedFixtureCleanup, as: Cleanup

  alias Marshall.Compute.{
    Credentials,
    Drains,
    Enrollment,
    EnrollmentPreparation,
    Host,
    HostCredential,
    Ledger
  }

  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000
  @moduletag :tmp_dir

  # @cc [owner:ghuntley,label:verification] committed-fixture-suite-preservation
  # Every schedule MUST restore its complete pre-test row inventory, including
  # historical rows. Teardown checks are reported independently of the body.
  setup do
    {before, images_before} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        {Marshall.CommittedFixtureInventory.snapshot(), Cleanup.fixture_image_ids()}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Cleanup.images!(Cleanup.fixture_image_ids() -- images_before)
        Marshall.CommittedFixtureInventory.assert_restored!(before)
      end)
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] enrollment-three-independent-peers
  # Every race MUST use three distinct BEAM nodes with independent Repo pools
  # and shared committed PostgreSQL state; the parent runner is not a peer.
  setup_all do
    peers =
      Enum.map(
        [:marshall_enrollment_1, :marshall_enrollment_2, :marshall_enrollment_3],
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
          peer
        end
      )

    %{peers: peers}
  end

  @spec enrollment_request(String.t(), String.t()) :: map()
  defp enrollment_request(name, machine) do
    %{
      "version" => 3,
      "name" => name,
      "architecture" => "x86_64",
      "machine_id" => machine,
      "overhead_cores" => 1,
      "overhead_memory_bytes" => 1_073_741_824,
      "credential_ttl_seconds" => 3600,
      "pools" => [
        %{
          "name" => "guests",
          "storage" => %{
            "backend" => "zfs",
            "zpool_guid" => Integer.to_string(System.unique_integer([:positive])),
            "dataset_guid" => Integer.to_string(System.unique_integer([:positive])),
            "dataset" => "tank/lilly"
          },
          "overhead_bytes" => 1_073_741_824
        }
      ]
    }
  end

  @spec machine_id() :: String.t()
  defp machine_id,
    do: "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  @spec write_request(String.t(), map()) :: String.t()
  defp write_request(dir, request) do
    path = Path.join(dir, "request-#{Ash.UUID.generate()}.json")
    File.write!(path, JSON.encode!(request))
    File.chmod!(path, 0o600)
    path
  end

  @spec gate_race([pid()], [{atom(), atom(), [term()]}]) :: [term()]
  defp gate_race(peers, calls) do
    caller = self()

    tasks =
      for {peer, {module, function, args}} <- Enum.zip(peers, calls) do
        Task.async(fn ->
          send(caller, {:gated, self()})
          receive do: (:go -> :ok)
          :peer.call(peer, module, function, args, 60_000)
        end)
      end

    for _ <- tasks, do: assert_receive({:gated, _pid}, 10_000)
    for task <- tasks, do: send(task.pid, :go)
    Task.await_many(tasks, 90_000)
  end

  # @cc [owner:ghuntley,label:verification] enrollment-fixture-ownership
  # Committed fixtures MUST remove only their own host rows and derived history
  # in key order; the complete-table audit then verifies no other residue.
  @spec cleanup_hosts([String.t()]) :: :ok
  defp cleanup_hosts(host_ids) do
    ids = Enum.map(host_ids, &Ecto.UUID.dump!/1)

    Cleanup.lifecycle!(host_ids, [])

    Cleanup.jobs!(
      "args->'primary_key'->>'id' IN (SELECT id::text FROM compute_host_drains WHERE host_id = ANY($1::uuid[]))",
      [ids]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM compute_lifecycle_events WHERE host_id = ANY($1::uuid[])",
      [ids]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM compute_host_drains_versions WHERE version_source_id IN (SELECT id FROM compute_host_drains WHERE host_id = ANY($1::uuid[]))",
      [ids]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM compute_host_drains WHERE host_id = ANY($1::uuid[])",
      [
        ids
      ]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM compute_enrollment_operations WHERE host_id = ANY($1::uuid[])",
      [ids]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM compute_host_credentials_versions WHERE version_source_id IN (SELECT id FROM compute_host_credentials WHERE host_id = ANY($1::uuid[]))",
      [ids]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM compute_host_credentials WHERE host_id = ANY($1::uuid[])",
      [ids]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM compute_host_sessions WHERE host_id = ANY($1::uuid[])",
      [
        ids
      ]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM compute_storage_pools WHERE host_id = ANY($1::uuid[])",
      [
        ids
      ]
    )

    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_hosts WHERE id = ANY($1::uuid[])", [ids])
    :ok
  end

  # @cc [owner:ghuntley,label:verification] enrollment-prepare-three-node-name-lock
  # Identical same-name preparations on independent nodes MUST converge on one
  # registration and one credential; conflicting machines MUST refuse all but
  # one requester. Deterministic before/after outcomes prove the per-name lock.
  test "three nodes converge or refuse same-name deployments", %{peers: peers, tmp_dir: dir} do
    File.chmod!(dir, 0o700)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      name = "race-name-" <> String.replace(Ash.UUID.generate(), "-", "")
      path = write_request(dir, enrollment_request(name, machine_id()))

      try do
        results =
          gate_race(
            peers,
            for _ <- peers do
              {EnrollmentPreparation, :prepare_file,
               [
                 Ash.UUID.generate(),
                 :prepare,
                 path,
                 Path.join(dir, "out-#{Ash.UUID.generate()}.json")
               ]}
            end
          )

        assert Enum.all?(results, &match?({:ok, _}, &1))
        [host_id] = Enum.uniq(Enum.map(results, fn {:ok, public} -> public.host_id end))
        [credential] = Ledger.read!(HostCredential, host_id: host_id)
        ops = Ledger.read!(Marshall.Compute.EnrollmentOperation, host_id: host_id)
        assert length(ops) == 3
        assert Enum.all?(ops, &(&1.credential_id == credential.id))

        conflicting =
          write_request(dir, enrollment_request(name, machine_id()))

        refused =
          gate_race(
            peers,
            for _ <- peers do
              {EnrollmentPreparation, :prepare_file,
               [
                 Ash.UUID.generate(),
                 :prepare,
                 conflicting,
                 Path.join(dir, "conflict-#{Ash.UUID.generate()}.json")
               ]}
            end
          )

        assert Enum.all?(refused, &match?({:error, :registration_conflict}, &1))
        assert Ledger.read!(Host, name: name) |> length() == 1
      after
        for host <- Ledger.read!(Host, name: name) do
          cleanup_hosts([host.id])
        end
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] enrollment-conflict-one-winner
  # Conflicting same-name machines raced on three nodes MUST produce exactly
  # one registered machine identity; every loser MUST refuse registration.
  test "three nodes serialize conflicting same-name machines to one winner", %{
    peers: peers,
    tmp_dir: dir
  } do
    File.chmod!(dir, 0o700)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      name = "race-conflict-" <> String.replace(Ash.UUID.generate(), "-", "")
      requests = Enum.map(1..3, fn _ -> enrollment_request(name, machine_id()) end)
      paths = Enum.map(requests, &write_request(dir, &1))

      try do
        results =
          gate_race(
            peers,
            Enum.zip(paths, 1..3)
            |> Enum.map(fn {path, index} ->
              {EnrollmentPreparation, :prepare_file,
               [Ash.UUID.generate(), :prepare, path, Path.join(dir, "winner-#{index}.json")]}
            end)
          )

        winners = Enum.filter(results, &match?({:ok, _}, &1))
        losers = Enum.filter(results, &match?({:error, _}, &1))
        assert length(winners) == 1
        assert Enum.all?(losers, &match?({:error, :registration_conflict}, &1))

        [{winner_index, {:ok, winner}}] =
          Enum.with_index(results, fn value, index -> {index, value} end)
          |> Enum.filter(fn {_, r} -> match?({:ok, _}, r) end)

        assert [%{id: host_id, machine_id: machine}] = Ledger.read!(Host, name: name)
        assert host_id == winner.host_id
        assert machine == Enum.at(requests, winner_index)["machine_id"]
        assert [_] = Ledger.read!(HostCredential, host_id: host_id)

        assert {:ok, verified} =
                 Enrollment.verify_file(Path.join(dir, "winner-#{winner_index + 1}.json"))

        assert verified.host_id == host_id
      after
        for host <- Ledger.read!(Host, name: name) do
          cleanup_hosts([host.id])
        end
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] enrollment-rotation-host-lock-three-peers
  # Concurrent manual rotations on three nodes MUST serialize on the host lock:
  # each committed rotation issues exactly once, exactly one credential stays
  # active, and a shared prepared-operation retry never rotates again.
  test "three nodes race rotations and one idempotent operation retry", %{
    peers: peers,
    tmp_dir: dir
  } do
    File.chmod!(dir, 0o700)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      fixture = Marshall.ComputeFixtures.host_fixture(%{transfer_endpoint: nil})
      host_id = fixture.host.id
      outputs = Enum.map(1..3, &Path.join(dir, "rotated-#{&1}-#{Ash.UUID.generate()}.json"))

      try do
        results =
          gate_race(
            peers,
            Enum.map(outputs, fn out -> {Enrollment, :rotate_file, [host_id, 3600, out]} end)
          )

        assert Enum.all?(results, &match?({:ok, _}, &1))
        [active] = Ledger.read!(HostCredential, host_id: host_id)

        history = Ledger.history!(HostCredential, host_id: host_id)
        # Exactly the three committed rotations; the fixture issued nothing before.
        assert length(history) == 3

        active_index =
          Enum.find_index(results, fn {:ok, public} -> public.credential_id == active.id end)

        assert active_index != nil

        for {out, index} <- Enum.with_index(outputs) do
          if index == active_index do
            assert {:ok, verified} = Enrollment.verify_file(out)
            assert verified.credential_id == active.id
          else
            assert {:error, :credential_inactive} = Enrollment.verify_file(out)
          end
        end

        survivor_token =
          outputs
          |> Enum.at(active_index)
          |> File.read!()
          |> JSON.decode!()
          |> Map.fetch!("credential")

        assert {:ok, :ok} = Credentials.with_host(survivor_token, fn _host -> :ok end)

        # A prepared rotation raced from every node issues exactly once.
        pool = fixture.pool

        request = %{
          "version" => 3,
          "name" => fixture.host.name,
          "architecture" => "x86_64",
          "machine_id" => fixture.host.machine_id,
          "overhead_cores" => fixture.host.overhead_cores,
          "overhead_memory_bytes" => fixture.host.overhead_memory_bytes,
          "credential_ttl_seconds" => 3600,
          "pools" => [
            %{
              "name" => pool.name,
              "storage" => %{
                "backend" => "zfs",
                "zpool_guid" => pool.zpool_guid,
                "dataset_guid" => pool.dataset_guid,
                "dataset" => pool.dataset
              },
              "overhead_bytes" => pool.overhead_bytes
            }
          ]
        }

        request_path = write_request(dir, request)
        operation = Ash.UUID.generate()
        op_outputs = Enum.map(1..3, &Path.join(dir, "op-#{&1}-#{Ash.UUID.generate()}.json"))

        retried =
          gate_race(
            peers,
            Enum.map(op_outputs, fn out ->
              {EnrollmentPreparation, :prepare_file, [operation, :rotate, request_path, out]}
            end)
          )

        assert Enum.all?(retried, &match?({:ok, _}, &1))
        rotated_ids = Enum.uniq(Enum.map(retried, fn {:ok, public} -> public.credential_id end))
        assert length(rotated_ids) == 1
        assert [rotated_id] = rotated_ids
        assert rotated_id != active.id
        assert length(Ledger.read!(Marshall.Compute.EnrollmentOperation, id: operation)) == 1
        assert length(Ledger.history!(HostCredential, host_id: host_id)) == 4
        assert [%{id: ^rotated_id}] = Ledger.read!(HostCredential, host_id: host_id)

        [first | rest] = Enum.map(op_outputs, &File.read!/1)
        assert Enum.all?(rest, &(&1 == first))
      after
        cleanup_hosts([host_id])
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] enrollment-retire-fences-rotation-race
  # Retirement racing direct rotations on three nodes MUST end retired with no
  # active credential: a rotation committed earlier loses to the retirement's
  # revocation; a rotation arriving later MUST hit the retired fence in the
  # shared host lock order.
  test "retirement fences concurrent rotations into one terminal retired state", %{
    peers: peers,
    tmp_dir: _dir
  } do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      fixture = Marshall.ComputeFixtures.host_fixture(%{transfer_endpoint: nil})
      host_id = fixture.host.id
      drain_id = Ash.UUID.generate()

      try do
        assert {:ok, %{status: "draining"}} = Drains.request(host_id, drain_id, "verify112:race")
        assert {:ok, 0} = Drains.advance(drain_id)
        assert {:ok, %{status: "drained"}} = Drains.status(drain_id)

        results =
          gate_race(peers, [
            {Drains, :retire, [drain_id]},
            {Credentials, :rotate, [host_id, 3600]},
            {Credentials, :rotate, [host_id, 3600]}
          ])

        # Races close in the closed class: committed rotation, retired-fenced
        # rotation, committed retirement, or a quiescence wait for fresh evidence.
        assert Enum.all?(results, fn
                 {:ok, %Credentials.Issued{}} -> true
                 {:ok, %{status: "retired"}} -> true
                 {:error, :host_retired} -> true
                 {:error, :host_not_quiescent} -> true
                 _ -> false
               end)

        # A rotation landing between drain confirmation and retirement revokes the
        # fresh report that quiescence requires; retirement then waits for fresh
        # evidence. Settle deterministically, then assert the terminal invariants.
        settle_retired(host_id, drain_id)

        # Every rotation the race committed is either already revoked by the
        # retirement or was refused by the retired fence after it.
        [host] = Ledger.read!(Host, id: host_id)
        assert host.maintenance_mode == :retired
        refute host.enabled
        assert [] == Ledger.read!(HostCredential, host_id: host_id)

        for {:ok, issued} <- Enum.filter(results, &match?({:ok, _}, &1)) do
          assert {:error, :unauthorized} =
                   Credentials.with_host(issued.token, fn _host -> :ok end)
        end

        # Late direct rotation MUST hit the retired fence, not resurrect authority.
        assert {:error, :host_retired} = Credentials.rotate(host_id, 3600)
        assert [] == Ledger.read!(HostCredential, host_id: host_id)

        # The retired row persists as evidence with its drained history.
        assert {:ok, %{status: "retired", host_mode: "retired"}} = Drains.status(drain_id)
      after
        cleanup_hosts([host_id])

        Cleanup.jobs!(
          "args->'primary_key'->>'id' = $1",
          [drain_id]
        )
      end
    end)
  end

  # @spec settle_retired(String.t(), String.t()) :: :ok
  defp settle_retired(host_id, drain_id) do
    [host] = Ledger.read!(Host, id: host_id)

    unless host.maintenance_mode == :retired do
      {:ok, issued} = Credentials.rotate(host_id, 3600)

      {:ok, session} =
        Marshall.Compute.ProvisionerControl.open_execution(issued.token, %{
          session_id: Ash.UUID.generate(),
          machine_id: host.machine_id
        })

      pool = hd(Ledger.read!(Marshall.Compute.StoragePool, host_id: host_id))

      {:ok, _} =
        Marshall.Compute.ProvisionerControl.exchange_execution(issued.token, %{
          session_id: session["session_id"],
          epoch: session["epoch"],
          report: fresh_report(pool),
          acknowledgements: [],
          outcomes: []
        })

      assert {:ok, %{status: "retired"}} = Drains.retire(drain_id)
    end

    :ok
  end

  @spec fresh_report(Marshall.Compute.StoragePool.t()) :: map()
  defp fresh_report(pool) do
    %{
      sequence: 1000,
      sampled_at: Ledger.now(),
      effective_cores: 5,
      effective_memory_bytes: 4_294_967_296,
      inventory: %{
        "architecture" => "x86_64",
        "images" => [],
        "execution_ready" => true,
        "terminal_protocol" => 2,
        "inception_image_id" => nil
      },
      pools: [
        %{
          id: pool.id,
          total_bytes: pool.total_bytes,
          free_bytes: pool.free_bytes,
          allocations: %{},
          storage: %{
            backend: :zfs,
            zpool_guid: pool.zpool_guid,
            dataset_guid: pool.dataset_guid,
            dataset: pool.dataset,
            used_bytes: 0,
            logical_used_bytes: 0,
            quota_bytes: pool.total_bytes,
            compression_ratio: 1.0
          }
        }
      ]
    }
  end
end
