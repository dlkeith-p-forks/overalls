defmodule Marshall.EvacuationHistoryFixture do
  @moduledoc "Disposable evacuation authority gates and complete persisted-row observations."
  alias Marshall.Accounts.User
  alias Marshall.Compute.{Evacuation, EvacuationItem, Host, Ledger, Operation, VirtualMachine}
  alias Marshall.JobHistoryFixture

  @type command :: :pause | :continue | :approve | :replan | :lock | :signout | :advance
  @type snapshot :: %{String.t() => [[map()]]}

  @spec invoke(module(), atom(), [term()]) :: {:completed, JobHistoryFixture.outcome()}
  defdelegate invoke(module, function, arguments), to: JobHistoryFixture

  @spec act(command(), String.t(), User.t()) :: {:ok, term()} | {:error, term()}
  def act(:lock, _id, actor), do: Marshall.PasskeyFixture.action(actor, :lock)
  def act(:advance, id, _actor), do: Marshall.Compute.Evacuations.advance(id)

  def act(:signout, _id, actor),
    do: JobHistoryFixture.act(:signout, 1, actor, actor, "unused")

  def act(command, id, actor) when command in [:approve, :replan] do
    [item] = Ledger.read!(EvacuationItem, evacuation_id: id)
    args = %{id: id, item_id: item.id, expected_key: item.request_key}

    if command == :approve,
      do: Marshall.Compute.approve_evacuation_downtime(args, actor: actor),
      else: Marshall.Compute.replan_evacuation_workload(args, actor: actor)
  end

  def act(command, id, actor),
    do: Marshall.Compute.control_evacuation(%{id: id, command: command}, actor: actor)

  @spec request(String.t(), String.t(), User.t()) :: {:ok, map()} | {:error, term()}
  def request(host, id, actor),
    do: Marshall.Compute.request_evacuation(%{host_id: host, request_id: id}, actor: actor)

  @spec workload(User.t()) :: VirtualMachine.t()
  def workload(actor) do
    {:ok, vm} = Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    Ledger.update!(operation, :complete, %{})
    Ledger.update!(vm, :observe, %{observed_state: :running})
  end

  # @cc [owner:ghuntley,label:verification] evacuation-real-guest-identity-lock-order
  # This consumer MUST retain the real personal-terminal VM-before-User order.
  # Its gate precedes GuestAccounts.ensure!, so early evacuation actor retention
  # is observable as a real deadlock, not an inferred queue relationship.
  @spec guest_identity(String.t(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def guest_identity(vm, actor, gate) do
    Ledger.transaction(fn ->
      Ledger.lock!(VirtualMachine, vm)
      query("SELECT pg_advisory_xact_lock($1)", [gate])
      Marshall.Accounts.GuestAccounts.ensure!(actor).id
    end)
  end

  @spec snapshot(String.t(), String.t()) :: snapshot()
  def snapshot(host, campaign) do
    source_id = Ecto.UUID.cast!(host)
    host = Ecto.UUID.dump!(host)
    campaign = Ecto.UUID.dump!(campaign)

    vms =
      "SELECT vm_id FROM compute_evacuation_items WHERE evacuation_id=$1 UNION SELECT vm_id FROM compute_workload_placements WHERE host_id='#{source_id}'"

    items = "SELECT id FROM compute_evacuation_items WHERE evacuation_id=$1"
    moves = "SELECT id FROM compute_relocations WHERE evacuation_id=$1"
    roots = "SELECT id FROM agent_roots WHERE vm_id IN (#{vms})"
    threads = "SELECT id FROM agent_threads WHERE root_id IN (#{roots})"

    keys =
      "SELECT id::text FROM compute_evacuations WHERE id=$1 UNION SELECT id::text FROM compute_operations WHERE vm_id IN (#{vms}) UNION SELECT id::text FROM compute_relocations WHERE evacuation_id=$1"

    jobs = "SELECT id FROM oban_jobs WHERE args->'primary_key'->>'id' IN (#{keys})"

    Map.new(
      [
        {"compute_hosts", "id=$1", host},
        {"compute_evacuations", "id=$1", campaign},
        {"compute_evacuations_versions", "version_source_id=$1", campaign},
        {"compute_evacuation_items", "evacuation_id=$1", campaign},
        {"compute_evacuation_items_versions", "version_source_id IN (#{items})", campaign},
        {"compute_virtual_machines", "id IN (#{vms})", campaign},
        {"compute_virtual_machines_versions", "version_source_id IN (#{vms})", campaign},
        {"agent_roots", "vm_id IN (#{vms})", campaign},
        {"agent_roots_versions", "version_source_id IN (#{roots})", campaign},
        {"agent_threads", "root_id IN (#{roots})", campaign},
        {"agent_threads_versions", "version_source_id IN (#{threads})", campaign},
        {"agent_audit_events", "vm_id IN (#{vms})", campaign},
        {"compute_workload_placements", "vm_id IN (#{vms})", campaign},
        {"compute_operations", "vm_id IN (#{vms})", campaign},
        {"compute_network_addresses", "vm_id IN (#{vms})", campaign},
        {"compute_reservations", "vm_id IN (#{vms})", campaign},
        {"compute_transfer_slots",
         "source_relocation_id IN (#{moves}) OR destination_relocation_id IN (#{moves})",
         campaign},
        {"compute_relocations", "evacuation_id=$1", campaign},
        {"compute_lifecycle_events",
         "resource_id=$1 OR resource_id IN (#{items}) OR vm_id IN (#{vms})", campaign},
        {"account_admin_events", "target_id=$1 OR target_id IN (#{items})", campaign},
        {"oban_jobs", "id IN (#{jobs})", campaign},
        {"admin_job_snapshots", "id IN (#{jobs})", campaign},
        {"admin_job_events", "job_id IN (#{jobs})", campaign}
      ],
      fn {table, filter, id} ->
        {table,
         query("SELECT to_jsonb(r) FROM #{table} r WHERE #{filter} ORDER BY id", [id]).rows}
      end
    )
  end

  # @cc [owner:ghuntley,label:verification] evacuation-real-write-gate
  # The gate MUST suspend the actual production audit/elevation write without
  # adding authority locks; independent peers MUST observe only committed rows.
  @spec install_gate(
          :request | :advance | :pause | :approve | :replan | :lock | :signout,
          String.t(),
          String.t(),
          pos_integer()
        ) :: :ok
  def install_gate(operation, campaign, actor, gate) do
    campaign = Ecto.UUID.cast!(campaign)
    actor = Ecto.UUID.cast!(actor)

    {table, event, condition} =
      case operation do
        command when command in [:request, :pause, :approve, :replan] ->
          kind =
            %{
              request: "evacuation_request",
              pause: "evacuation_control",
              approve: "evacuation_approve",
              replan: "evacuation_replan"
            }[command]

          {"account_admin_events", "INSERT", "NEW.actor_id='#{actor}' AND NEW.kind='#{kind}'"}

        :advance ->
          {"compute_relocations", "INSERT", "NEW.evacuation_id='#{campaign}'"}

        :lock ->
          {"account_verifications", "UPDATE",
           "NEW.user_id='#{actor}' AND NEW.elevated_until IS NULL"}

        :signout ->
          {"tokens", "UPDATE", "NEW.subject='user?id=#{actor}' AND NEW.purpose='revocation'"}
      end

    query("""
    CREATE FUNCTION #{name(campaign)}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{condition} THEN PERFORM pg_advisory_xact_lock(#{gate}); END IF;
      RETURN NEW;
    END; $$
    """)

    query(
      "CREATE TRIGGER #{name(campaign)} BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name(campaign)}()"
    )

    :ok
  end

  @spec remove_gate(
          :request | :advance | :pause | :approve | :replan | :lock | :signout,
          String.t()
        ) :: :ok
  def remove_gate(operation, campaign) do
    table =
      case operation do
        :advance -> "compute_relocations"
        :lock -> "account_verifications"
        :signout -> "tokens"
        _ -> "account_admin_events"
      end

    query("DROP TRIGGER IF EXISTS #{name(campaign)} ON #{table}")
    query("DROP FUNCTION IF EXISTS #{name(campaign)}()")
    :ok
  end

  @spec cleanup(Host.t(), User.t()) :: :ok
  def cleanup(host, user) do
    for campaign <- Ledger.read!(Evacuation, host_id: host.id) do
      id = Ecto.UUID.dump!(campaign.id)

      %{rows: jobs} =
        query("DELETE FROM oban_jobs WHERE args->'primary_key'->>'id'=$1 RETURNING id", [
          campaign.id
        ])

      for [job] <- jobs do
        query("DELETE FROM admin_job_events WHERE job_id=$1", [job])
        query("DELETE FROM admin_job_snapshots WHERE id=$1", [job])
      end

      query("DELETE FROM account_admin_events WHERE target_id=$1", [id])

      query(
        "DELETE FROM compute_evacuation_items_versions WHERE version_source_id IN (SELECT id FROM compute_evacuation_items WHERE evacuation_id=$1)",
        [id]
      )

      query("DELETE FROM compute_evacuation_items WHERE evacuation_id=$1", [id])

      for move <- Ledger.read!(Marshall.Compute.Relocation, evacuation_id: campaign.id) do
        key = Ecto.UUID.dump!(move.id)

        %{rows: jobs} =
          query("DELETE FROM oban_jobs WHERE args->'primary_key'->>'id'=$1 RETURNING id", [
            move.id
          ])

        for [job] <- jobs do
          query("DELETE FROM admin_job_events WHERE job_id=$1", [job])
          query("DELETE FROM admin_job_snapshots WHERE id=$1", [job])
        end

        query(
          "DELETE FROM compute_transfer_slots WHERE source_relocation_id=$1 OR destination_relocation_id=$1",
          [key]
        )

        query("DELETE FROM compute_relocations WHERE id=$1", [key])
      end

      query("DELETE FROM compute_evacuations_versions WHERE version_source_id=$1", [id])
      query("DELETE FROM compute_lifecycle_events WHERE resource_id=$1", [id])
      query("DELETE FROM compute_evacuations WHERE id=$1", [id])
    end

    for vm <- Ledger.read!(VirtualMachine, owner_id: user.id) do
      id = Ecto.UUID.dump!(vm.id)

      # Public provisioning registers eligible agent history in the same
      # transaction. Delete only this workload's fixture history before its VM.
      roots = "SELECT id FROM agent_roots WHERE vm_id=$1"
      threads = "SELECT id FROM agent_threads WHERE root_id IN (#{roots})"

      for {table, filter} <- [
            {"agent_audit_events", "vm_id=$1"},
            {"agent_threads_versions", "version_source_id IN (#{threads})"},
            {"agent_threads", "root_id IN (#{roots})"},
            {"agent_roots_versions", "version_source_id IN (#{roots})"},
            {"agent_roots", "vm_id=$1"}
          ] do
        query("DELETE FROM #{table} WHERE #{filter}", [id])
      end

      %{rows: jobs} =
        query(
          "DELETE FROM oban_jobs WHERE args->'primary_key'->>'id' IN (SELECT id::text FROM compute_operations WHERE vm_id=$1) RETURNING id",
          [id]
        )

      for [job] <- jobs do
        query("DELETE FROM admin_job_events WHERE job_id=$1", [job])
        query("DELETE FROM admin_job_snapshots WHERE id=$1", [job])
      end

      for table <- [
            "compute_operations",
            "compute_reservations",
            "compute_network_addresses",
            "compute_lifecycle_events"
          ] do
        query("DELETE FROM #{table} WHERE vm_id=$1", [id])
      end

      for table <- ["ingress_endpoints", "access_grants"] do
        query(
          "DELETE FROM #{table}_versions WHERE version_source_id IN (SELECT id FROM #{table} WHERE vm_id=$1)",
          [id]
        )

        query("DELETE FROM #{table} WHERE vm_id=$1", [id])
      end

      query("DELETE FROM compute_virtual_machines_versions WHERE version_source_id=$1", [id])

      query(
        "WITH removed AS (DELETE FROM compute_workload_placements WHERE vm_id=$1 RETURNING vm_id) DELETE FROM compute_virtual_machines WHERE id IN (SELECT vm_id FROM removed)",
        [id]
      )
    end

    id = Ecto.UUID.dump!(host.id)
    query("DELETE FROM compute_storage_pools WHERE host_id=$1", [id])
    query("DELETE FROM compute_host_sessions WHERE host_id=$1", [id])
    query("DELETE FROM compute_hosts WHERE id=$1", [id])
    Marshall.AdminAccountFixture.cleanup([user])
    :ok
  end

  # @cc [owner:ghuntley,label:verification] evacuation-fixture-agent-history
  # Provisioned fixture cleanup MUST remove its root, thread, audit and their
  # versions on success and failure while preserving unrelated preexisting rows.
  @spec agent_inventory() :: snapshot()
  def agent_inventory do
    Map.new(
      ~w(agent_roots agent_roots_versions agent_threads agent_threads_versions agent_audit_events),
      fn table -> {table, query("SELECT to_jsonb(r) FROM #{table} r ORDER BY id").rows} end
    )
  end

  # @cc [owner:ghuntley,label:verification] evacuation-cleanup-original-failure
  # Cleanup faults MUST NOT replace the original schedule failure. A successful
  # schedule MUST still fail on unsuccessful cleanup; both outcomes remain visible.
  @spec with_cleanup(Host.t() | [Host.t()], User.t(), (-> result)) :: result when result: term()
  def with_cleanup(host, user, body) do
    outcome = capture(body)

    cleaned =
      capture(fn ->
        Enum.each(List.wrap(host), &cleanup(&1, user))
        :ok
      end)

    case {outcome, cleaned} do
      {{:raised, kind, reason, stack}, {:raised, _, _, _}} ->
        IO.puts(:stderr, "Evacuation fixture cleanup also failed; original assertion retained")
        :erlang.raise(kind, reason, stack)

      {{:raised, kind, reason, stack}, _} ->
        :erlang.raise(kind, reason, stack)

      {{:ok, _}, {:raised, kind, reason, stack}} ->
        :erlang.raise(kind, reason, stack)

      {{:ok, result}, {:ok, :ok}} ->
        result
    end
  end

  @spec capture((-> term())) :: JobHistoryFixture.outcome()
  defp capture(body) do
    try do
      {:ok, body.()}
    catch
      kind, reason -> {:raised, kind, reason, __STACKTRACE__}
    end
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  defdelegate query(sql, params \\ []), to: JobHistoryFixture

  @spec name(String.t()) :: String.t()
  defp name(id), do: "evacuation_history_gate_" <> String.replace(Ecto.UUID.cast!(id), "-", "_")
end
