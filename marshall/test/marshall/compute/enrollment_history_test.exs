defmodule Marshall.Compute.EnrollmentHistoryTest do
  @moduledoc "Generated enrollment/credential/maintenance histories against a pure model oracle."
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Accounts.AdminEvent
  alias Marshall.Compute

  alias Marshall.Compute.{
    Credentials,
    Drains,
    Enrollment,
    EnrollmentOperation,
    EnrollmentPreparation,
    Host,
    HostCredential,
    HostDrain,
    HostSession,
    Ledger,
    ProvisionerControl,
    StoragePool
  }

  import Marshall.ComputeFixtures, only: [user: 0]

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @typep issuance :: %{
           id: String.t(),
           token: String.t(),
           path: String.t(),
           bytes: String.t(),
           expires_at: String.t()
         }

  @typep fixture :: %{
           request: map(),
           request_path: String.t(),
           host_id: String.t(),
           machine_id: String.t(),
           name: String.t(),
           pool: StoragePool.t(),
           admin: Marshall.Accounts.User.t(),
           owner: Marshall.Accounts.User.t(),
           tmp_dir: String.t()
         }

  @typep drain_state :: %{id: String.t(), status: atom(), open: boolean()}

  @typep state :: %{
           retired: boolean(),
           maintenance: :normal | :draining | :evacuating | :retired,
           enabled: boolean(),
           ready: boolean(),
           active: nil | issuance(),
           issued: [issuance()],
           operations: %{String.t() => %{kind: :prepare | :rotate, credential: issuance()}},
           initial_op: String.t(),
           last_prepare: String.t(),
           last_rotate: nil | String.t(),
           epoch: non_neg_integer(),
           session: nil | String.t(),
           stale_sessions: [String.t()],
           report_sequence: non_neg_integer(),
           drain: nil | drain_state(),
           closed_drains: [drain_state()],
           admin_events: non_neg_integer(),
           vm: boolean(),
           vm_stopped: boolean()
         }

  @tables [
    "compute_hosts",
    "compute_storage_pools",
    "compute_host_credentials",
    "compute_host_credentials_versions",
    "compute_host_sessions",
    "compute_enrollment_operations",
    "compute_host_drains",
    "compute_host_drains_versions",
    "account_admin_events",
    "compute_virtual_machines",
    "compute_reservations",
    "compute_network_addresses",
    "compute_operations"
  ]

  @weights [
    {:prepare, 2},
    {:retry_prepare, 2},
    {:rotate_prepared, 2},
    {:retry_rotate, 2},
    {:rotate_manual, 2},
    {:revoke, 1},
    {:verify_newest, 3},
    {:verify_oldest, 2},
    {:open_new, 2},
    {:open_replay, 3},
    {:open_stale, 2},
    {:report, 4},
    {:enable, 3},
    {:disable, 2},
    {:drain, 1},
    {:retry_drain, 1},
    {:advance, 2},
    {:resume, 1},
    {:retire, 1}
  ]

  # @cc [owner:ghuntley,label:verification] enrollment-generated-histories
  # Histories MUST drive the real Ash actions and the authenticated control
  # exchange against a pure host model, keep at most one active credential per
  # host, permanently fence retired identity, drive enablement through both entry
  # points under one freshness/readiness oracle, refuse operations without any
  # table change, retain every closed drain row across a later request, and
  # MUST end retired.
  @tag :hegel
  test "generated histories converge with the oracle and end retired", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    op_gen = frequency(Enum.map(@weights, fn {op, weight} -> {weight, constant(op)} end))

    check all(generated <- list_of(op_gen, min_length: 6, max_length: 18), test_cases: 12) do
      {state, fixture} = fixture(dir)
      history = generated ++ [:rotate_manual, :open_new, :report, :drain, :advance, :retire]
      state = Enum.reduce(history, state, fn op, current -> step(op, current, fixture) end)
      terminal_sweep(state, fixture)
    end
  end

  test "a resumed drain remains in history after a new drain request", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    {state, fixture} = fixture(dir)

    state =
      Enum.reduce([:open_new, :report, :drain, :advance, :resume, :drain], state, fn op,
                                                                                     current ->
        step(op, current, fixture)
      end)

    assert [%{status: :resumed, open: false}] = state.closed_drains
    assert %{status: :draining, open: true} = state.drain
    assert_state!(state, fixture)
  end

  # @cc [owner:ghuntley,label:verification] enrollment-rotation-reservation-stability
  # Credential rotation, revocation, admission toggles and maintenance requests
  # on a host holding a guest reservation MUST leave every reservation row
  # byte-identical; retirement MUST be refused while resources remain.
  @tag :hegel
  test "credential histories preserve live guest reservations byte for byte", %{
    tmp_dir: dir
  } do
    File.chmod!(dir, 0o700)

    ops = [
      :rotate_prepared,
      :retry_rotate,
      :rotate_manual,
      :revoke,
      :verify_newest,
      :verify_oldest,
      :open_new,
      :open_replay,
      :report,
      :enable,
      :disable,
      :drain,
      :retry_drain,
      :advance,
      :retire
    ]

    check all(
            generated <- list_of(member_of(ops), min_length: 5, max_length: 14),
            test_cases: 12
          ) do
      {state, fixture} = fixture(dir)
      Marshall.ComputeFixtures.image_fixture()
      state = step(:open_new, state, fixture)
      state = step(:report, state, fixture)
      state = step(:enable, state, fixture)
      assert state.enabled

      assert {:ok, _vm} =
               Compute.provision(Marshall.ComputeFixtures.request(), actor: fixture.owner)

      reservations_before = reservation_rows(fixture)
      assert reservations_before != []
      state = %{state | vm: true}

      state =
        Enum.reduce(generated ++ [:open_new, :report, :drain, :advance], state, fn op, current ->
          step(op, current, fixture)
        end)

      # The retained reservation fences retirement even after a confirmed drain.
      assert state.drain != nil and state.drain.open

      refused(state, fixture, fn ->
        assert {:error, _} = Drains.retire(state.drain.id)
      end)

      assert reservation_rows(fixture) == reservations_before
      terminal_sweep_active(state, fixture)
    end
  end

  # ---------------------------------------------------------------------------
  # Fixture construction through the real enrollment boundary
  # ---------------------------------------------------------------------------

  @spec fixture(String.t()) :: {state(), fixture()}
  defp fixture(tmp_dir) do
    Marshall.ComputeFixtures.image_fixture()
    name = "hist-" <> String.replace(Ash.UUID.generate(), "-", "")
    machine = "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    zpool = Integer.to_string(System.unique_integer([:positive]))
    dataset = Integer.to_string(System.unique_integer([:positive]))

    request = %{
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
            "zpool_guid" => zpool,
            "dataset_guid" => dataset,
            "dataset" => "tank/lilly"
          },
          "overhead_bytes" => 1_073_741_824
        }
      ]
    }

    request_path = Path.join(tmp_dir, "request-#{name}.json")
    File.write!(request_path, JSON.encode!(request))
    File.chmod!(request_path, 0o600)

    operation = Ash.UUID.generate()
    output = Path.join(tmp_dir, "enrolled-#{name}.json")

    assert {:ok, public} =
             EnrollmentPreparation.prepare_file(operation, :prepare, request_path, output)

    refute public.enabled
    [host] = Ledger.read!(Host, id: public.host_id)
    refute host.enabled
    assert host.reported_at == nil
    [pool] = Ledger.read!(StoragePool, host_id: host.id)

    active = issuance(output)
    assert active.id == public.credential_id

    admin =
      user()
      |> Ledger.update!(:assign_administrator, %{administrator: true})
      |> Marshall.PasskeyFixture.verified_session()

    fixture = %{
      request: request,
      request_path: request_path,
      host_id: host.id,
      machine_id: machine,
      name: name,
      pool: pool,
      admin: admin,
      owner: user(),
      tmp_dir: tmp_dir
    }

    state = %{
      retired: false,
      maintenance: :normal,
      enabled: false,
      ready: false,
      active: active,
      issued: [active],
      operations: %{operation => %{kind: :prepare, credential: active}},
      initial_op: operation,
      last_prepare: operation,
      last_rotate: nil,
      epoch: 1,
      session: nil,
      stale_sessions: [],
      report_sequence: 0,
      drain: nil,
      closed_drains: [],
      admin_events: 0,
      vm: false,
      vm_stopped: false
    }

    {state, fixture}
  end

  @spec issuance(Path.t()) :: issuance()
  defp issuance(path) do
    bytes = File.read!(path)
    decoded = JSON.decode!(bytes)

    %{
      id: decoded["credential_id"],
      token: decoded["credential"],
      path: path,
      bytes: bytes,
      expires_at: decoded["expires_at"]
    }
  end

  @spec output_path(fixture(), String.t()) :: String.t()
  defp output_path(fixture, prefix) do
    Path.join(fixture.tmp_dir, "#{prefix}-#{Ash.UUID.generate()}.json")
  end

  # ---------------------------------------------------------------------------
  # Pure-oracle readiness predicates (shared by both admission entry points)
  # ---------------------------------------------------------------------------

  @spec fresh_window() :: non_neg_integer()
  defp fresh_window, do: Application.fetch_env!(:marshall, :capacity_freshness_ms)

  @spec read_host(fixture()) :: Host.t()
  defp read_host(fixture), do: hd(Ledger.read!(Host, id: fixture.host_id))

  @spec ready?(Host.t(), DateTime.t()) :: boolean()
  defp ready?(host, now) do
    host.inventory["execution_ready"] == true and
      Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, now)
  end

  @spec quiescent?(state(), Host.t()) :: boolean()
  defp quiescent?(state, host) do
    not state.vm and ready?(host, Ledger.now())
  end

  # Freshness predictions read the same row and database clock as the
  # implementation; operations straddling the freshness boundary first age the
  # observed row out, making the outcome deterministic rather than racy.
  @spec settle_boundary(fixture()) :: :ok
  defp settle_boundary(fixture) do
    case read_host(fixture).reported_at do
      nil ->
        :ok

      reported ->
        window = fresh_window()
        age = DateTime.diff(Ledger.now(), reported, :millisecond)

        if age >= window - 700 and age <= window + 700 do
          Process.sleep(window + 701 - age)
        end

        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Refusal inventory (complete-table equality around refused operations)
  # ---------------------------------------------------------------------------

  @spec inventory() :: %{String.t() => [map()]}
  defp inventory do
    Map.new(@tables, fn table ->
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(Repo, "SELECT to_jsonb(r) FROM #{table} r ORDER BY id", [],
          log: false
        )

      {table, rows}
    end)
  end

  @spec refused(state(), fixture(), (-> term())) :: :ok
  defp refused(_state, _fixture, action) do
    before = inventory()
    action.()
    assert inventory() == before
    :ok
  end

  @spec reservation_rows(fixture()) :: [String.t()]
  defp reservation_rows(fixture) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT md5(row_to_json(r)::text) FROM compute_reservations r WHERE host_id=$1 ORDER BY id",
        [Ecto.UUID.dump!(fixture.host_id)],
        log: false
      )

    Enum.map(rows, fn [digest] -> digest end)
  end

  @spec report(fixture(), non_neg_integer()) :: map()
  defp report(fixture, sequence) do
    pool = fixture.pool

    %{
      sequence: sequence,
      sampled_at: Ledger.now(),
      effective_cores: 8,
      effective_memory_bytes: 8_589_934_592,
      inventory: %{
        "architecture" => "x86_64",
        "images" => [Marshall.ComputeFixtures.image_id()],
        "execution_ready" => true,
        "terminal_protocol" => 2,
        "inception_image_id" => nil
      },
      capacity: %{
        "version" => 1,
        "cpu_headroom_millicores" => 8000,
        "memory_headroom_bytes" => 8_589_934_592,
        "interval_us" => 1_000_000,
        "covered" => %{}
      },
      pools: [
        %{
          id: pool.id,
          total_bytes: 10_737_418_240,
          free_bytes: 10_737_418_240,
          allocations: %{},
          storage: %{
            backend: :zfs,
            zpool_guid: pool.zpool_guid,
            dataset_guid: pool.dataset_guid,
            dataset: pool.dataset,
            used_bytes: 0,
            logical_used_bytes: 0,
            quota_bytes: 10_737_418_240,
            compression_ratio: 1.0
          }
        }
      ]
    }
  end

  @spec push_stale(state()) :: [String.t()]
  defp push_stale(%{session: nil, stale_sessions: stale}), do: stale
  defp push_stale(%{session: session, stale_sessions: stale}), do: [session | stale]

  @spec active_token(state()) :: String.t()
  defp active_token(%{active: %{token: token}}), do: token
  defp active_token(%{issued: [issuance | _]}), do: issuance.token

  # ---------------------------------------------------------------------------
  # Operation implementations: real actions checked against the model
  # ---------------------------------------------------------------------------

  @spec step(atom(), state(), fixture()) :: state()
  defp step(op, state, fixture) do
    next = run_op(op, state, fixture)
    assert_state!(next, fixture)
    next
  end

  @spec run_op(atom(), state(), fixture()) :: state()
  defp run_op(:prepare, state, fixture) do
    operation = Ash.UUID.generate()
    out = output_path(fixture, "prepare")

    cond do
      state.retired ->
        refused(state, fixture, fn ->
          assert {:error, :host_retired} =
                   EnrollmentPreparation.prepare_file(
                     operation,
                     :prepare,
                     fixture.request_path,
                     out
                   )
        end)

        assert File.read!(out) == ""
        state

      state.active == nil ->
        refused(state, fixture, fn ->
          assert {:error, :credential_inactive} =
                   EnrollmentPreparation.prepare_file(
                     operation,
                     :prepare,
                     fixture.request_path,
                     out
                   )
        end)

        assert File.read!(out) == ""
        state

      true ->
        assert {:ok, public} =
                 EnrollmentPreparation.prepare_file(
                   operation,
                   :prepare,
                   fixture.request_path,
                   out
                 )

        assert public.credential_id == state.active.id
        assert public.enabled == state.enabled
        assert File.read!(out) == state.active.bytes

        operations =
          Map.put(state.operations, operation, %{kind: :prepare, credential: state.active})

        %{state | operations: operations, last_prepare: operation}
    end
  end

  defp run_op(:retry_prepare, state, fixture) do
    operation = state.last_prepare
    recorded = Map.fetch!(state.operations, operation)
    out = output_path(fixture, "retry-prepare")

    cond do
      state.retired ->
        refused(state, fixture, fn ->
          assert {:error, :host_retired} =
                   EnrollmentPreparation.prepare_file(
                     operation,
                     :prepare,
                     fixture.request_path,
                     out
                   )
        end)

        state

      state.active == nil ->
        refused(state, fixture, fn ->
          assert {:error, :credential_inactive} =
                   EnrollmentPreparation.prepare_file(
                     operation,
                     :prepare,
                     fixture.request_path,
                     out
                   )
        end)

        state

      Map.fetch!(recorded, :credential).id == state.active.id ->
        assert {:ok, public} =
                 EnrollmentPreparation.prepare_file(
                   operation,
                   :prepare,
                   fixture.request_path,
                   out
                 )

        assert public.credential_id == recorded.credential.id
        assert File.read!(out) == recorded.credential.bytes
        state

      true ->
        refused(state, fixture, fn ->
          assert {:error, :credential_inactive} =
                   EnrollmentPreparation.prepare_file(
                     operation,
                     :prepare,
                     fixture.request_path,
                     out
                   )
        end)

        state
    end
  end

  defp run_op(:rotate_prepared, state, fixture) do
    operation = Ash.UUID.generate()
    out = output_path(fixture, "rotate")

    if state.retired do
      refused(state, fixture, fn ->
        assert {:error, :host_retired} =
                 EnrollmentPreparation.prepare_file(operation, :rotate, fixture.request_path, out)
      end)

      assert File.read!(out) == ""
      state
    else
      assert {:ok, public} =
               EnrollmentPreparation.prepare_file(operation, :rotate, fixture.request_path, out)

      next = rotate_effects(state, issuance(out))
      assert public.credential_id == next.active.id

      operations =
        Map.put(next.operations, operation, %{kind: :rotate, credential: next.active})

      %{next | operations: operations, last_rotate: operation}
    end
  end

  defp run_op(:retry_rotate, state, fixture) do
    case state.last_rotate do
      nil when state.retired ->
        refused(state, fixture, fn ->
          assert {:error, :host_retired} =
                   EnrollmentPreparation.prepare_file(
                     Ash.UUID.generate(),
                     :rotate,
                     fixture.request_path,
                     output_path(fixture, "retired-rotate")
                   )
        end)

        state

      nil ->
        # A rotate-kind replay of a prepare operation must conflict on kind.
        refused(state, fixture, fn ->
          assert {:error, :operation_conflict} =
                   EnrollmentPreparation.prepare_file(
                     state.initial_op,
                     :rotate,
                     fixture.request_path,
                     output_path(fixture, "kind-conflict")
                   )
        end)

        state

      operation ->
        recorded = Map.fetch!(state.operations, operation)
        out = output_path(fixture, "retry-rotate")

        cond do
          state.retired ->
            refused(state, fixture, fn ->
              assert {:error, :host_retired} =
                       EnrollmentPreparation.prepare_file(
                         operation,
                         :rotate,
                         fixture.request_path,
                         out
                       )
            end)

            state

          state.active != nil and Map.fetch!(recorded, :credential).id == state.active.id ->
            assert {:ok, public} =
                     EnrollmentPreparation.prepare_file(
                       operation,
                       :rotate,
                       fixture.request_path,
                       out
                     )

            assert public.credential_id == recorded.credential.id
            assert File.read!(out) == recorded.credential.bytes
            state

          true ->
            refused(state, fixture, fn ->
              assert {:error, :credential_inactive} =
                       EnrollmentPreparation.prepare_file(
                         operation,
                         :rotate,
                         fixture.request_path,
                         out
                       )
            end)

            state
        end
    end
  end

  defp run_op(:rotate_manual, state, fixture) do
    out = output_path(fixture, "manual-rotate")

    if state.retired do
      refused(state, fixture, fn ->
        assert {:error, :host_retired} = Enrollment.rotate_file(fixture.host_id, 3600, out)
      end)

      assert File.read!(out) == ""
      state
    else
      assert {:ok, public} = Enrollment.rotate_file(fixture.host_id, 3600, out)
      next = rotate_effects(state, issuance(out))
      assert public.credential_id == next.active.id
      next
    end
  end

  defp run_op(:revoke, state, fixture) do
    assert {:ok, %{revoked: true}} = Enrollment.revoke(fixture.host_id)

    %{
      state
      | active: nil,
        epoch: state.epoch + 1,
        session: nil,
        stale_sessions: push_stale(state),
        ready: false
    }
  end

  defp run_op(:verify_newest, state, fixture) do
    verify_against(state, fixture, newest_issuance(state))
    state
  end

  defp run_op(:verify_oldest, state, fixture) do
    verify_against(state, fixture, oldest_stale_issuance(state))
    state
  end

  defp run_op(:open_new, state, fixture) do
    open_check(state, fixture, Ash.UUID.generate())
  end

  defp run_op(:open_replay, state, fixture) do
    if state.session == nil do
      run_op(:open_new, state, fixture)
    else
      sid = state.session

      if state.active == nil or state.retired do
        refused(state, fixture, fn ->
          assert {:error, :unauthorized} =
                   ProvisionerControl.open_execution(active_token(state), %{
                     session_id: sid,
                     machine_id: fixture.machine_id
                   })
        end)

        state
      else
        assert {:ok, session} =
                 ProvisionerControl.open_execution(state.active.token, %{
                   session_id: sid,
                   machine_id: fixture.machine_id
                 })

        assert session["epoch"] == state.epoch
        assert session["session_id"] == sid
        state
      end
    end
  end

  defp run_op(:open_stale, state, fixture) do
    case state.stale_sessions do
      [] ->
        run_op(:open_new, state, fixture)

      [sid | _] ->
        if state.active == nil or state.retired do
          refused(state, fixture, fn ->
            assert {:error, :unauthorized} =
                     ProvisionerControl.open_execution(active_token(state), %{
                       session_id: sid,
                       machine_id: fixture.machine_id
                     })
          end)
        else
          refused(state, fixture, fn ->
            assert {:error, :stale_connection} =
                     ProvisionerControl.open_execution(state.active.token, %{
                       session_id: sid,
                       machine_id: fixture.machine_id
                     })
          end)
        end

        state
    end
  end

  defp run_op(:report, state, fixture) do
    sequence = state.report_sequence + 1
    report = report(fixture, sequence)

    cond do
      state.retired or state.active == nil ->
        refused(state, fixture, fn ->
          assert {:error, :unauthorized} =
                   ProvisionerControl.exchange_execution(active_token(state), %{
                     session_id: state.session || Ash.UUID.generate(),
                     epoch: state.epoch,
                     report: report,
                     acknowledgements: [],
                     outcomes: []
                   })
        end)

        state

      state.session == nil ->
        refused(state, fixture, fn ->
          assert {:error, :stale_connection} =
                   ProvisionerControl.exchange_execution(state.active.token, %{
                     session_id: Ash.UUID.generate(),
                     epoch: state.epoch,
                     report: report,
                     acknowledgements: [],
                     outcomes: []
                   })
        end)

        state

      true ->
        assert {:ok, response} =
                 ProvisionerControl.exchange_execution(state.active.token, %{
                   session_id: state.session,
                   epoch: state.epoch,
                   report: report,
                   acknowledgements: [],
                   outcomes: []
                 })

        assert response["epoch"] == state.epoch
        next = %{state | report_sequence: sequence, ready: true}

        case state.drain do
          %{open: true, status: :draining} = drain ->
            if quiescent?(state, read_host(fixture)),
              do: %{next | drain: %{drain | status: :drained}},
              else: next

          _ ->
            next
        end
    end
  end

  defp run_op(:enable, state, fixture) do
    settle_boundary(fixture)
    host = read_host(fixture)

    allowed =
      host.maintenance_mode == :normal and ready?(host, Ledger.now())

    overheads = %{overhead_cores: 1, overhead_memory_bytes: 1_073_741_824}

    if allowed do
      assert {:ok, %{enabled: true}} = Enrollment.set_enabled(fixture.host_id, true)

      # Enabling commits only over a fresh report row.
      assert read_host(fixture).reported_at != nil

      assert {:ok, %{enabled: true}} =
               Compute.admin_configure_host(
                 Map.merge(%{host_id: fixture.host_id, enabled: true}, overheads),
                 actor: fixture.admin
               )

      %{state | enabled: true, admin_events: state.admin_events + 1}
    else
      refused(state, fixture, fn ->
        assert {:error, reason} = Enrollment.set_enabled(fixture.host_id, true)
        assert reason in [:host_in_maintenance, :host_not_ready]

        assert {:error, _} =
                 Compute.admin_configure_host(
                   Map.merge(%{host_id: fixture.host_id, enabled: true}, overheads),
                   actor: fixture.admin
                 )
      end)

      state
    end
  end

  defp run_op(:disable, state, fixture) do
    assert {:ok, %{enabled: false}} = Enrollment.set_enabled(fixture.host_id, false)

    assert {:ok, %{enabled: false}} =
             Compute.admin_configure_host(
               Map.merge(
                 %{host_id: fixture.host_id, enabled: false},
                 %{overhead_cores: 1, overhead_memory_bytes: 1_073_741_824}
               ),
               actor: fixture.admin
             )

    %{state | enabled: false, admin_events: state.admin_events + 1}
  end

  defp run_op(:drain, state, fixture) do
    id = Ash.UUID.generate()

    if (state.drain != nil and state.drain.open) or state.retired or
         state.maintenance != :normal do
      refused(state, fixture, fn ->
        assert {:error, :host_in_maintenance} = Drains.request(fixture.host_id, id, "verify112")
      end)

      state
    else
      assert {:ok, snapshot} = Drains.request(fixture.host_id, id, "verify112")
      assert snapshot.status == "draining"
      assert snapshot.host_mode == "draining"
      assert snapshot.enabled == false

      %{
        state
        | maintenance: :draining,
          enabled: false,
          drain: %{id: id, status: :draining, open: true},
          closed_drains:
            if(state.drain, do: [state.drain | state.closed_drains], else: state.closed_drains)
      }
    end
  end

  defp run_op(:retry_drain, state, fixture) do
    case state.drain do
      nil ->
        run_op(:drain, state, fixture)

      drain ->
        assert {:ok, snapshot} = Drains.request(fixture.host_id, drain.id, "verify112")
        assert snapshot.status == Atom.to_string(drain.status)
        state
    end
  end

  defp run_op(:advance, state, fixture) do
    case state.drain do
      %{open: true, status: :draining} = drain ->
        settle_boundary(fixture)
        could_confirm = quiescent?(state, read_host(fixture))
        expected_stops = if state.vm and not state.vm_stopped, do: 1, else: 0
        assert {:ok, stopped} = Drains.advance(drain.id)
        assert stopped == expected_stops
        state = %{state | vm_stopped: state.vm_stopped or expected_stops == 1}

        if could_confirm,
          do: %{state | drain: %{drain | status: :drained}},
          else: state

      _ ->
        refused(state, fixture, fn ->
          assert {:error, :unknown_drain} = Drains.advance(Ash.UUID.generate())
        end)

        state
    end
  end

  defp run_op(:resume, state, fixture) do
    case state.drain do
      %{open: true, status: :drained} = drain ->
        settle_boundary(fixture)

        if quiescent?(state, read_host(fixture)) do
          assert {:ok, snapshot} = Drains.resume(drain.id)
          assert snapshot.status == "resumed"

          %{
            state
            | maintenance: :normal,
              enabled: true,
              drain: %{drain | status: :resumed, open: false}
          }
        else
          refused(state, fixture, fn ->
            assert {:error, :host_not_quiescent} = Drains.resume(drain.id)
          end)

          state
        end

      _ ->
        refused(state, fixture, fn ->
          assert {:error, :unknown_drain} = Drains.resume(Ash.UUID.generate())
        end)

        state
    end
  end

  defp run_op(:retire, state, fixture) do
    case state.drain do
      %{status: :retired} = drain ->
        assert {:ok, snapshot} = Drains.retire(drain.id)
        assert snapshot.status == "retired"
        state

      %{open: true, status: :drained} = drain ->
        settle_boundary(fixture)
        host = read_host(fixture)

        if quiescent?(state, host) do
          assert {:ok, snapshot} = Drains.retire(drain.id)
          assert snapshot.status == "retired"

          %{
            state
            | maintenance: :retired,
              retired: true,
              enabled: false,
              active: nil,
              epoch: state.epoch + 1,
              session: nil,
              stale_sessions: push_stale(state),
              ready: false,
              drain: %{drain | status: :retired, open: false}
          }
        else
          refused(state, fixture, fn ->
            assert {:error, reason} = Drains.retire(drain.id)
            assert reason in [:host_not_quiescent, :retained_host_resources]
          end)

          state
        end

      %{open: true} = drain ->
        refused(state, fixture, fn ->
          assert {:error, :host_not_quiescent} = Drains.retire(drain.id)
        end)

        state

      _ ->
        refused(state, fixture, fn ->
          assert {:error, :unknown_drain} = Drains.retire(Ash.UUID.generate())
        end)

        state
    end
  end

  # ---------------------------------------------------------------------------
  # Shared effects and verification helpers
  # ---------------------------------------------------------------------------

  @spec rotate_effects(state(), issuance()) :: state()
  defp rotate_effects(state, issued) do
    %{
      state
      | active: issued,
        issued: [issued | state.issued],
        epoch: state.epoch + 1,
        session: nil,
        stale_sessions: push_stale(state),
        ready: false
    }
  end

  @spec open_check(state(), fixture(), String.t()) :: state()
  defp open_check(state, fixture, sid) do
    if state.active == nil or state.retired do
      refused(state, fixture, fn ->
        assert {:error, :unauthorized} =
                 ProvisionerControl.open_execution(active_token(state), %{
                   session_id: sid,
                   machine_id: fixture.machine_id
                 })
      end)

      state
    else
      assert {:ok, session} =
               ProvisionerControl.open_execution(state.active.token, %{
                 session_id: sid,
                 machine_id: fixture.machine_id
               })

      epoch = state.epoch + 1
      assert session["epoch"] == epoch
      assert session["host_id"] == fixture.host_id
      assert session["session_id"] == sid

      %{
        state
        | epoch: epoch,
          session: sid,
          stale_sessions: push_stale(state),
          report_sequence: 0,
          ready: false
      }
    end
  end

  @spec newest_issuance(state()) :: issuance()
  defp newest_issuance(%{active: %{id: _} = active}), do: active
  defp newest_issuance(%{issued: [issuance | _]}), do: issuance

  @spec oldest_stale_issuance(state()) :: issuance()
  defp oldest_stale_issuance(state) do
    case Enum.find(Enum.reverse(state.issued), fn candidate ->
           state.active == nil or candidate.id != state.active.id
         end) do
      nil -> newest_issuance(state)
      candidate -> candidate
    end
  end

  @spec verify_against(state(), fixture(), issuance()) :: :ok
  defp verify_against(state, fixture, target) do
    if not state.retired and state.active != nil and state.active.id == target.id do
      assert {:ok, public} = Enrollment.verify_file(target.path)
      assert public.credential_id == target.id
      assert public.enabled == state.enabled
      assert public.maintenance_mode == Atom.to_string(state.maintenance)
      assert public.machine_id == fixture.machine_id
      assert public.name == fixture.name
    else
      refused(state, fixture, fn ->
        assert {:error, :credential_inactive} = Enrollment.verify_file(target.path)
      end)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # DB == oracle assertion after every step
  # ---------------------------------------------------------------------------

  @spec assert_state!(state(), fixture()) :: :ok
  defp assert_state!(state, fixture) do
    [host] = Ledger.read!(Host, id: fixture.host_id)
    assert host.enabled == state.enabled
    assert host.maintenance_mode == state.maintenance
    assert host.connection_epoch == state.epoch
    assert host.connection_session_id == state.session
    assert host.report_sequence == state.report_sequence
    assert host.reported_at != nil == state.ready

    credentials = Ledger.read!(HostCredential, host_id: fixture.host_id)
    assert length(credentials) == if(state.active, do: 1, else: 0)

    case state.active do
      nil ->
        :ok

      active ->
        [credential] = credentials
        assert credential.id == active.id
        assert DateTime.to_iso8601(credential.expires_at) == active.expires_at
    end

    # Persistent signal: rotation/revoke deliberately severs readiness after
    # admission; the enable step asserts a fresh report at its own commit.
    if host.enabled do
      assert host.maintenance_mode == :normal
      assert host.inventory["execution_ready"] == true
    end

    sessions = Ledger.read!(HostSession, host_id: fixture.host_id)

    assert length(sessions) ==
             length(state.stale_sessions) + if(state.session, do: 1, else: 0)

    if state.session do
      [session] = Enum.filter(sessions, &(&1.id == state.session))
      assert session.epoch == state.epoch
    end

    assert length(Ledger.read!(AdminEvent, target_id: fixture.host_id)) == state.admin_events

    operations = Ledger.read!(EnrollmentOperation, host_id: fixture.host_id)
    assert length(operations) == map_size(state.operations)

    for row <- operations do
      assert Map.fetch!(state.operations, row.id).credential.id == row.credential_id
      assert row.request == fixture.request
    end

    expected_drains =
      if state.drain, do: [state.drain | state.closed_drains], else: state.closed_drains

    drains = Ledger.read!(HostDrain, host_id: fixture.host_id)
    assert length(drains) == length(expected_drains)

    for expected <- expected_drains do
      [row] = Enum.filter(drains, &(&1.id == expected.id))
      assert row.status == expected.status
      assert is_nil(row.closed_at) == expected.open
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Terminal sweeps
  # ---------------------------------------------------------------------------

  # @cc [owner:ghuntley,label:verification;security] enrollment-terminal-retired-fence
  # After every history the retired host MUST refuse issuance, sessions and
  # verification forever, every issue credential and file MUST be inert, and the
  # persisted row MUST remain as retired evidence.
  @spec terminal_sweep(state(), fixture()) :: :ok
  defp terminal_sweep(state, fixture) do
    assert state.retired

    for issuance <- state.issued do
      refused(state, fixture, fn ->
        assert {:error, :unauthorized} =
                 Credentials.with_host(issuance.token, fn _host -> :ok end)

        assert {:error, :credential_inactive} = Enrollment.verify_file(issuance.path)
      end)
    end

    refused(state, fixture, fn ->
      assert {:error, :host_retired} =
               EnrollmentPreparation.prepare_file(
                 Ash.UUID.generate(),
                 :prepare,
                 fixture.request_path,
                 output_path(fixture, "post-prepare")
               )

      assert {:error, :host_retired} =
               EnrollmentPreparation.prepare_file(
                 Ash.UUID.generate(),
                 :rotate,
                 fixture.request_path,
                 output_path(fixture, "post-rotate")
               )

      assert {:error, :host_retired} =
               Enrollment.rotate_file(fixture.host_id, 3600, output_path(fixture, "post-manual"))
    end)

    # Post-retirement identity revocation still succeeds as a no-op.
    assert {:ok, %{revoked: true}} = Enrollment.revoke(fixture.host_id)
    state = %{state | epoch: state.epoch + 1}
    assert_state!(state, fixture)

    [host] = Ledger.read!(Host, id: fixture.host_id)
    assert host.maintenance_mode == :retired
    assert host.enabled == false
    assert Ledger.read!(HostCredential, host_id: fixture.host_id) == []
    :ok
  end

  @spec terminal_sweep_active(state(), fixture()) :: :ok
  defp terminal_sweep_active(state, fixture) do
    refute state.retired

    for issuance <- state.issued do
      active? = state.active != nil and state.active.id == issuance.id

      if active? do
        assert {:ok, :ok} = Credentials.with_host(issuance.token, fn _host -> :ok end)
        assert {:ok, _} = Enrollment.verify_file(issuance.path)
      else
        refused(state, fixture, fn ->
          assert {:error, :unauthorized} =
                   Credentials.with_host(issuance.token, fn _host -> :ok end)

          assert {:error, :credential_inactive} = Enrollment.verify_file(issuance.path)
        end)
      end
    end

    assert_state!(state, fixture)
  end
end
