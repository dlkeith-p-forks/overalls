defmodule Marshall.CloneVerificationFixture do
  @moduledoc "Synthetic clone receipts and disposable independent-node barriers."
  alias Marshall.Compute.{
    CloneCoordinator,
    CloneEffect,
    CloneRequest,
    Ledger,
    Operation,
    VirtualMachine
  }

  alias Marshall.Repo
  import Marshall.ComputeFixtures, only: [image_id: 0]

  @type phase ::
          :queued
          | :preparing
          | :stopping
          | :capturing
          | :copying
          | :publishing
          | :cleaning
          | :complete
          | :cancelling
          | :cancelled
          | :failed
  @type json :: nil | boolean() | number() | String.t() | [json()] | json_object()
  @type json_object :: %{String.t() => json()}
  @type snapshot :: %{
          id: String.t(),
          source_vm_id: String.t(),
          destination_vm_id: String.t(),
          requested_by_id: String.t(),
          request_key: String.t(),
          name: String.t(),
          requested_name: String.t() | nil,
          sequence: pos_integer(),
          active: boolean(),
          phase: phase(),
          source_host_id: String.t() | nil,
          destination_host_id: String.t() | nil,
          original_power_state: :running | :stopped | nil,
          specification: json_object(),
          snapshot: json_object() | nil,
          source_operation_id: String.t() | nil,
          destination_operation_id: String.t() | nil,
          source_restored_at: DateTime.t() | nil,
          published_at: DateTime.t() | nil,
          cancel_requested_at: DateTime.t() | nil,
          failure: String.t() | nil,
          finished_at: DateTime.t() | nil,
          name_released_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
  @type view :: %{
          id: String.t(),
          source_vm_id: String.t(),
          destination_vm_id: String.t(),
          name: String.t(),
          phase: phase(),
          active: boolean(),
          failure: String.t() | nil,
          original_power_state: :running | :stopped | nil,
          source_restored_at: DateTime.t() | nil,
          published_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          queue_position: non_neg_integer() | nil
        }
  @type action_result ::
          {:ok, CloneRequest.t() | view() | :absent | :finished | :idle | :queued}
          | {:error, Exception.t()}
  @type effect_kind ::
          :prepare | :probe | :connect | :capture | :copy | :adopt | :revoke | :discard | :prune
  @type effect_result ::
          :empty
          | {:public_key, String.t()}
          | {:dataset_guid, String.t()}
          | {:descriptor, json_object()}
  @type outcome(value) ::
          {:ok, value} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  # @cc [owner:ghuntley,label:verification] clone-peer-completion
  # Only a peer-side completed envelope establishes that the remote call stopped.
  # A caller with an uncertain RPC outcome MUST stop that peer before row cleanup.
  @spec invoke(module(), atom(), [term()]) :: {:completed, outcome(term())}
  def invoke(module, function, arguments) do
    outcome =
      try do
        {:ok, apply(module, function, arguments)}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    {:completed, outcome}
  end

  @spec request(String.t()) :: CloneRequest.t()
  def request(id), do: hd(Ledger.read!(CloneRequest, id: id))

  @spec snapshot(String.t()) :: snapshot()
  def snapshot(id),
    do: Map.take(request(id), Enum.map(Ash.Resource.Info.attributes(CloneRequest), & &1.name))

  @spec advance(String.t()) :: :ok
  def advance(id) do
    {:ok, _} = CloneCoordinator.advance(id)
    :ok
  end

  # @cc [owner:ghuntley,label:verification] clone-synthetic-receipt-scope
  # Synthetic outcomes MUST enter the production receipt/coordinator path and
  # MUST NOT be described as evidence of native disk ownership or reclamation.
  @spec settle(VirtualMachine.t(), Operation.t(), :running | :stopped | :failed) :: :ok
  def settle(vm, operation, state) do
    event = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: operation.generation,
      state: state,
      compute_empty: state != :running,
      disk_present: true,
      cleanup_complete: false,
      reason: if(state == :failed, do: :execution_failed, else: :none)
    }

    {:ok, event} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    {:ok, _} =
      Ledger.transaction(fn ->
        Ledger.lock!(Marshall.Compute.Host, vm.host_id)
        Marshall.Compute.Outcomes.ingest_locked!(vm.host_id, [event])
      end)

    :ok
  end

  @spec settle_source(String.t(), :running | :stopped | :failed) :: :ok
  def settle_source(id, state) do
    clone = request(id)
    [vm] = Ledger.read!(VirtualMachine, id: clone.source_vm_id)
    [operation] = Ledger.read!(Operation, id: clone.source_operation_id)
    settle(vm, operation, state)
  end

  @spec effect(String.t(), effect_kind(), effect_result(), :source | :destination | nil) :: :ok
  def effect(id, kind, result, endpoint \\ nil) do
    wire =
      case result do
        :empty ->
          %{}

        {:public_key, key} ->
          %{"public_key" => key}

        {:dataset_guid, guid} ->
          %{"dataset_guid" => guid}

        {:descriptor, descriptor} ->
          {:ok, validated} = OverallsProtocol.DiskTransfer.descriptor(descriptor)
          %{"descriptor" => OverallsProtocol.DiskTransfer.encode_descriptor(validated)}
      end

    effects = Ledger.read!(CloneEffect, clone_request_id: id, kind: kind)
    if effects == [], do: raise("requested effect does not exist")

    for effect <- effects,
        (is_nil(endpoint) or effect.endpoint == endpoint) and is_nil(effect.completed_at) do
      Ledger.update!(effect, :complete, %{result: wire, completed_at: Ledger.now()})
    end

    :ok
  end

  @spec prepare(String.t()) :: :ok
  def prepare(id) do
    advance(id)

    effect(id, :prepare, {:public_key, Marshall.ComputeFixtures.transfer_endpoint()["host_key"]})

    advance(id)
    effect(id, :probe, :empty)
    advance(id)
    effect(id, :connect, :empty)
    advance(id)
  end

  @spec capture(String.t()) :: :ok
  def capture(id) do
    descriptor =
      Map.put(Marshall.Compute.CloneEffects.intent(request(id)), "stream", %{
        "source_dataset_guid" => "100",
        "to_guid" => "101"
      })

    effect(id, :capture, {:descriptor, descriptor})
    advance(id)
  end

  # @cc [owner:ghuntley,label:verification] clone-observed-query-barrier
  # A barrier MUST pause after the selected actual production lock or allocation query, without
  # acquiring the account/source lock for the implementation. Release MUST be
  # bounded and the telemetry handler removed on every return or exception.
  @spec gated_advance(String.t(), String.t()) :: action_result()
  def gated_advance(id, gate), do: gated(id, gate, :advance, nil)

  @spec gated(
          String.t(),
          String.t(),
          :advance | :cancel,
          Marshall.Accounts.User.t() | nil,
          :source | :allocation
        ) :: action_result()
  def gated(id, gate, operation, actor, stage \\ :source) do
    owner = self()
    source = request(id).source_vm_id
    handler = {__MODULE__, gate}

    :ok =
      :telemetry.attach(handler, [:marshall, :repo, :query], &__MODULE__.query_barrier/4, %{
        owner: owner,
        key: "clone-source:" <> source,
        gate: gate,
        stage: stage
      })

    try do
      case operation do
        :advance -> CloneCoordinator.advance(id)
        :cancel -> Marshall.Compute.cancel_clone(%{request_id: id}, actor: actor)
      end
    after
      :telemetry.detach(handler)
      :persistent_term.erase({__MODULE__, gate})
    end
  end

  @spec query_barrier(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          %{
            owner: pid(),
            key: String.t(),
            gate: String.t(),
            stage: :source | :allocation
          }
        ) ::
          :ok
  def query_barrier(_event, _measurements, metadata, config) do
    selected? =
      case config.stage do
        :source ->
          metadata.params == [config.key] and
            String.contains?(metadata.query, "pg_advisory_xact_lock")

        :allocation ->
          String.contains?(metadata.query, "INSERT INTO \"compute_virtual_machines\"")
      end

    if self() == config.owner and selected? and not Process.get({__MODULE__, config.gate}, false) do
      Process.put({__MODULE__, config.gate}, true)
      :persistent_term.put({__MODULE__, config.gate}, self())

      receive do
        {:release_clone_gate, gate} when gate == config.gate -> :ok
      after
        15_000 -> raise "clone query barrier expired"
      end
    end

    :ok
  end

  @spec gate_status(String.t()) :: pid() | nil
  def gate_status(gate), do: :persistent_term.get({__MODULE__, gate}, nil)

  @spec release(String.t()) :: :ok
  def release(gate) do
    if pid = gate_status(gate), do: send(pid, {:release_clone_gate, gate})
    :ok
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  def query(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params, log: false)

  # @cc [owner:ghuntley,label:verification] clone-cleanup-agent-registration-scope
  # Cleanup MUST remove automatically registered agent roots, threads, audits and
  # versions for the exact fixture placements before deleting their VM records.
  # Requester ownership alone MUST NOT select roots: manager clones can share a
  # source owned by another actor. Unrelated and detached agent history MUST remain.
  @spec cleanup(String.t(), String.t()) :: {:ok, Postgrex.Result.t()}
  def cleanup(host_id, owner_id) do
    # Each test deletes only its committed fixture records, in FK order.
    # SQL is appropriate for test teardown, not a production lifecycle action.
    {:ok, _} =
      Repo.transaction(fn ->
        cleanup_agent_registrations(host_id)

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM oban_jobs WHERE args->'primary_key'->>'id' IN (SELECT id::text FROM compute_operations WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1))",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_physical_outcomes WHERE host_id = $1",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_operations WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        for sql <- [
              "DELETE FROM oban_jobs WHERE args->'primary_key'->>'id' IN (SELECT id::text FROM compute_clone_requests WHERE requested_by_id=$1)",
              "DELETE FROM compute_clone_effects WHERE clone_request_id IN (SELECT id FROM compute_clone_requests WHERE requested_by_id=$1)",
              "DELETE FROM compute_transfer_slots WHERE clone_request_id IN (SELECT id FROM compute_clone_requests WHERE requested_by_id=$1)",
              "DELETE FROM compute_clone_requests_versions WHERE version_source_id IN (SELECT id FROM compute_clone_requests WHERE requested_by_id=$1)",
              "DELETE FROM compute_clone_requests WHERE requested_by_id=$1",
              "DELETE FROM oban_jobs WHERE args->'primary_key'->>'id' IN (SELECT id::text FROM account_user_deletions WHERE user_id=$1)",
              "DELETE FROM account_user_deletions WHERE user_id=$1",
              "DELETE FROM account_admin_events WHERE target_id=$1"
            ],
            do: query(sql, [Ecto.UUID.dump!(owner_id)])

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_resize_requests WHERE host_id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_reservations WHERE host_id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_network_addresses WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        for {table, where} <- [
              {"ingress_endpoints_versions",
               "version_source_id IN (SELECT id FROM ingress_endpoints WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1))"},
              {"ingress_endpoints",
               "vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)"},
              {"terminal_tickets",
               "session_id IN (SELECT id FROM terminal_sessions WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1))"},
              {"terminal_events",
               "vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)"},
              {"terminal_sessions_versions",
               "version_source_id IN (SELECT id FROM terminal_sessions WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1))"},
              {"terminal_sessions",
               "vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)"},
              {"access_changes",
               "vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)"},
              {"access_grants_versions",
               "version_source_id IN (SELECT id FROM access_grants WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1))"},
              {"access_grants",
               "vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)"}
            ] do
          Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table} WHERE #{where}", [
            Ecto.UUID.dump!(host_id)
          ])
        end

        query(
          "DELETE FROM compute_lifecycle_events WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id=$1) OR host_id=$1",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_virtual_machines_versions WHERE version_source_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "WITH removed AS (DELETE FROM compute_workload_placements WHERE host_id = $1 RETURNING vm_id) DELETE FROM compute_virtual_machines WHERE id IN (SELECT vm_id FROM removed)",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_storage_pools WHERE host_id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_host_credentials_versions WHERE version_source_id IN (SELECT id FROM compute_host_credentials WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_host_credentials WHERE host_id = $1",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_host_sessions WHERE host_id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM oban_jobs WHERE args->'primary_key'->>'id' IN (SELECT id::text FROM compute_host_drains WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_host_drains_versions WHERE version_source_id IN (SELECT id FROM compute_host_drains WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_host_drains WHERE host_id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_hosts WHERE id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM tokens WHERE subject = $1", [
          "user?id=" <> owner_id
        ])

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM users WHERE id = $1 AND NOT EXISTS (SELECT 1 FROM compute_virtual_machines WHERE owner_id = $1)",
          [
            Ecto.UUID.dump!(owner_id)
          ]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_images_versions WHERE version_source_id = $1 AND NOT EXISTS (SELECT 1 FROM compute_virtual_machines WHERE image_id = $1)",
          [image_id()]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_images WHERE id = $1 AND NOT EXISTS (SELECT 1 FROM compute_virtual_machines WHERE image_id = $1)",
          [image_id()]
        )
      end)
  end

  @spec cleanup_agent_registrations(String.t()) :: :ok
  defp cleanup_agent_registrations(host_id) do
    # Capture bindings while VMs/placements still exist. Never sweep orphan roots
    # from earlier tests or use the requesting manager as the source owner.
    %{rows: roots} =
      query(
        """
        SELECT r.id, r.vm_id FROM agent_roots r
        JOIN compute_virtual_machines v ON v.id=r.vm_id AND v.owner_id=r.owner_id
        WHERE EXISTS (SELECT 1 FROM compute_workload_placements p
                      WHERE p.vm_id=v.id AND p.host_id=$1)
        """,
        [Ecto.UUID.dump!(host_id)]
      )

    root_ids = Enum.map(roots, fn [root, _vm] -> root end)
    vm_ids = Enum.map(roots, fn [_root, vm] -> vm end)

    query(
      "DELETE FROM agent_threads_versions WHERE version_source_id IN (SELECT id FROM agent_threads WHERE root_id=ANY($1::uuid[]))",
      [root_ids]
    )

    query("DELETE FROM agent_audit_events WHERE vm_id=ANY($1::uuid[])", [vm_ids])
    query("DELETE FROM agent_threads WHERE root_id=ANY($1::uuid[])", [root_ids])
    query("DELETE FROM agent_roots_versions WHERE version_source_id=ANY($1::uuid[])", [root_ids])
    query("DELETE FROM agent_roots WHERE id=ANY($1::uuid[])", [root_ids])
    :ok
  end
end
