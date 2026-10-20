defmodule Marshall.Scim.UserLifecycleObanTest do
  @moduledoc """
  SCIM user retirement through the endpoint, Oban jobs, the compute lifecycle
  coordinator and ingested physical outcomes.
  """
  use Marshall.DataCase, async: false
  use Oban.Testing, repo: Marshall.Repo
  import Marshall.ScimUserFixture

  alias Marshall.Accounts.{AccountLifecycle, User, UserDeletion}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, Lifecycle, Operation, WakeRequest}
  alias Marshall.Scim.RetirementWorker

  setup do
    %{host: Marshall.ComputeFixtures.host_fixture(), scim: enable!()}
  end

  @spec run_worker(String.t()) :: term()
  defp run_worker(user_id), do: perform_job(RetirementWorker, %{"user_id" => user_id})

  @spec kinds(String.t()) :: [atom()]
  defp kinds(vm_id), do: Ledger.read!(Operation, vm_id: vm_id) |> Enum.map(& &1.kind)

  test "machines pause at deactivation and are deleted only after the deadline", %{scim: scim} do
    user = create_user!(scim)
    running = [running_vm!(user)]
    own = running_vm!(user)
    owner_pause!(user, own)
    vm_ids = Enum.map(running, & &1.id)

    assert {200, _} = set_active(scim, user.id, false)
    assert_enqueued(worker: RetirementWorker, args: %{"user_id" => user.id})
    assert :ok = run_worker(user.id)

    for id <- vm_ids, do: assert(%{desired_state: :paused} = vm!(id))
    assert Enum.sort(Enum.map(suspensions(user.id), & &1.vm_id)) == Enum.sort(vm_ids)
    assert Enum.all?(suspensions(user.id), &(&1.state == :suspended and &1.kind == :pause))
    complete_operations!(vm_ids)
    for id <- vm_ids, do: assert(%{observed_state: :paused} = vm!(id))

    # Inside the grace period neither the worker, the deletion trigger action
    # nor the trusted coordinator may delete anything.
    assert :ok = run_worker(user.id)
    deletion = deletion(user.id)
    assert %UserDeletion{kind: :scim_retirement, state: :scheduled} = deletion

    assert {:ok, %{complete: false}} =
             UserDeletion
             |> Ash.ActionInput.for_action(:advance, %{primary_key: %{"id" => deletion.id}},
               actor: SystemActor.compute()
             )
             |> Ash.run_action()

    assert {:error, _} = Lifecycle.delete_for_account(deletion, own.id)
    for id <- [own.id | vm_ids], do: refute(:delete in kinds(id))

    expire!(user.id)
    assert {:snooze, _} = run_worker(user.id)
    for id <- [own.id | vm_ids], do: assert(:delete in kinds(id))
    refute user!(user.id).deleted_at, "identity finalizes only after physical reclamation"

    complete_operations!([own.id | vm_ids])
    assert :ok = run_worker(user.id)

    final = user!(user.id)
    assert final.deleted_at
    refute final.active
    assert to_string(final.email) == "deleted-#{user.id}@deleted.invalid"
    assert %UserDeletion{state: :completed, completed_at: %DateTime{}} = deletion(user.id)
    assert AccountLifecycle.owned_count(user.id) == 0
    assert Enum.all?(suspensions(user.id), &(&1.state == :released))

    # A finalized identity cannot be brought back by SCIM or by the worker.
    assert {400, _} = set_active(scim, user.id, true)
    assert :ok = run_worker(user.id)
    assert %User{active: false, deleted_at: %DateTime{}} = user!(user.id)
  end

  test "reactivation resumes only machines SCIM suspended", %{scim: scim} do
    user = create_user!(scim)
    scim_paused = running_vm!(user)
    self_paused = running_vm!(user)
    owner_pause!(user, self_paused)

    assert {200, _} = set_active(scim, user.id, false)
    assert :ok = run_worker(user.id)
    complete_operations!([scim_paused.id])
    assert [%{vm_id: vm_id, state: :suspended}] = suspensions(user.id)
    assert vm_id == scim_paused.id

    assert {200, %{"active" => true}} = set_active(scim, user.id, true)
    assert %UserDeletion{state: :cancelled} = deletion(user.id)
    assert :ok = run_worker(user.id)

    assert [%{state: :resumed}] = suspensions(user.id)
    assert [_] = Ledger.read!(WakeRequest, vm_id: scim_paused.id)
    assert [] == Ledger.read!(WakeRequest, vm_id: self_paused.id)
    assert %{desired_state: :paused} = vm!(self_paused.id)
    for id <- [scim_paused.id, self_paused.id], do: refute(:delete in kinds(id))

    # Replaying the reconciliation does not resume anything twice.
    assert :ok = run_worker(user.id)
    assert [_] = Ledger.read!(WakeRequest, vm_id: scim_paused.id)
  end

  test "reactivation before the physical pause completes still resumes", %{scim: scim} do
    user = create_user!(scim)
    vm = running_vm!(user)
    assert {200, _} = set_active(scim, user.id, false)
    assert :ok = run_worker(user.id)
    assert {200, _} = set_active(scim, user.id, true)
    assert :ok = run_worker(user.id)
    assert [%{state: :resumed}] = suspensions(user.id)
    assert [_] = Ledger.read!(WakeRequest, vm_id: vm.id)
  end

  test "a machine that cannot be checkpointed is stopped and later started", %{
    scim: scim,
    host: host
  } do
    user = create_user!(scim)
    vm = running_vm!(user)
    [current] = Ledger.read!(Marshall.Compute.Host, id: host.host.id)

    report = %{
      host.report
      | sequence: current.report_sequence + 1,
        sampled_at: Ledger.now(),
        inventory: Map.put(host.report.inventory, "checkpoint_image_ids", [])
    }

    assert {:ok, :ok} = Marshall.Compute.HostReports.ingest(host.host.id, host.epoch, report)

    assert {200, _} = set_active(scim, user.id, false)
    assert :ok = run_worker(user.id)
    assert %{desired_state: :stopped} = vm!(vm.id)
    assert [%{kind: :stop, state: :suspended}] = suspensions(user.id)
    complete_operations!([vm.id])

    assert {200, _} = set_active(scim, user.id, true)
    assert :ok = run_worker(user.id)
    assert %{desired_state: :running} = vm!(vm.id)
    assert [%{state: :resumed}] = suspensions(user.id)
  end

  test "an administrator retirement supersedes a scheduled SCIM retirement", %{scim: scim} do
    user = create_user!(scim)
    assert {200, _} = set_active(scim, user.id, false)
    email = to_string(user!(user.id).email)

    assert {:ok, %{deleting: true}} =
             User
             |> Ash.ActionInput.for_action(
               :delete_user,
               %{user_id: user.id, confirmation: email},
               actor: scim.admin
             )
             |> Ash.run_action()

    assert %UserDeletion{kind: :administrator, state: :scheduled} = deletion(user.id)
    assert user!(user.id).deleted_at
    assert :ok = run_worker(user.id)
  end

  test "the cron sweep re-enqueues every user with retirement work", %{scim: scim} do
    user = create_user!(scim)
    assert {200, _} = set_active(scim, user.id, false)
    Marshall.Repo.delete_all(Oban.Job)

    assert :ok = perform_job(RetirementWorker, %{})
    assert_enqueued(worker: RetirementWorker, args: %{"user_id" => user.id})
  end
end
