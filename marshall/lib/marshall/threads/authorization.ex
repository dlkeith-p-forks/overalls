defmodule Marshall.Threads.Authorization do
  @moduledoc "Fresh thread ACLs and their inherited authority on the current work machine."
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Authorization.{Cedar, DecisionSnapshot, SystemActor}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads.{Grant, Thread}
  require Ash.Query

  @type role :: :viewer | :operator | :manager
  @type grants :: %{optional(role()) => [String.t()]}
  @type permissions :: %{read: boolean(), write: boolean(), manage: boolean()}

  # @cc [owner:ghuntley,label:security] thread-current-cedar-authority
  # Thread authority MUST use the current account, immutable creator, current
  # thread grants and current team membership in Cedar. Direct machine grants
  # MUST NOT grant access to the thread or its retained transcript.
  @spec allowed?(Thread.t(), term(), String.t()) :: boolean()
  def allowed?(%Thread{} = thread, %User{} = actor, action)
      when action in ["read", "write", "manage"] do
    match?(%User{deleted_at: nil, active: true}, Security.current(thread.creator_id)) and
      Cedar.allowed?(actor, action, entity(thread, actor))
  end

  def allowed?(_, _, _), do: false

  @spec require!(Thread.t(), term(), String.t()) :: :ok
  def require!(thread, actor, action) do
    unless allowed?(thread, actor, action), do: Ledger.rollback(:forbidden)
    :ok
  end

  @spec permissions(Thread.t(), term()) :: permissions()
  def permissions(thread, actor) do
    %{
      read: allowed?(thread, actor, "read"),
      write: allowed?(thread, actor, "write"),
      manage: allowed?(thread, actor, "manage")
    }
  end

  @spec entity(Thread.t(), User.t()) :: ExCedar.Entity.t()
  defp entity(thread, actor) do
    grants = if shareable?(thread), do: grants_for(thread.id, actor.id), else: %{}
    teams = if shareable?(thread), do: team_grants(thread.team_id, actor.id), else: %{}
    Cedar.thread(thread.id, thread.creator_id, Map.merge(grants, teams))
  end

  @spec shareable?(Thread.t()) :: boolean()
  def shareable?(%Thread{machine_spec: spec}) do
    Map.get(spec, :profile, Map.get(spec, "profile")) in [
      :standard,
      :oss,
      :inception,
      "standard",
      "oss",
      "inception"
    ]
  end

  # @cc [owner:ghuntley,label:security;concurrency] thread-machine-acl-current-binding
  # Machine ACL inheritance MUST read only current thread bindings whose creator
  # matches the VM owner and whose VM profile permits sharing. Retired generations
  # MUST NOT inherit a reopened thread's grants. These helpers MUST NOT acquire
  # thread locks: their callers may already hold a VM lock.
  @spec machine_grants(VirtualMachine.t(), User.t()) :: grants()
  def machine_grants(vm, %User{id: user_id}) do
    case machine_thread(vm) do
      %Thread{id: id} -> grants_for(id, user_id)
      nil -> %{}
    end
  end

  @spec machine_user_ids(VirtualMachine.t()) :: [String.t()]
  def machine_user_ids(vm) do
    case machine_thread(vm) do
      %Thread{id: id} ->
        Grant
        |> Ash.Query.filter(thread_id == ^id)
        |> Ash.Query.limit(513)
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.map(& &1.user_id)

      nil ->
        []
    end
  end

  @bound_statuses [:pending, :provisioning, :ready, :failed, :deleting]

  @spec machine_thread(VirtualMachine.t()) :: Thread.t() | nil
  defp machine_thread(vm) do
    if inherits?(vm) do
      DecisionSnapshot.fetch({:machine_thread, vm.id}, fn ->
        Thread
        |> Ash.Query.filter(
          machine_id == ^vm.id and creator_id == ^vm.owner_id and status in ^@bound_statuses
        )
        |> Ash.Query.limit(2)
        |> Ash.read!(actor: SystemActor.compute())
        |> current_binding()
      end)
    end
  end

  defp inherits?(vm),
    do: OverallsProtocol.ProfilePolicy.allows?(vm.profile, :sharing) and is_nil(vm.archived_at)

  defp current_binding([thread]), do: if(shareable?(thread), do: thread)
  defp current_binding(_), do: nil

  @doc "Batch current machine thread bindings and the actor's thread grants for a page of VMs."
  @spec prefetch([VirtualMachine.t()], User.t()) :: :ok
  def prefetch(vms, %User{id: user_id}) do
    vms = Enum.filter(vms, &inherits?/1)

    if DecisionSnapshot.active?() and vms != [] do
      vm_ids = Enum.map(vms, & &1.id)
      owner_ids = vms |> Enum.map(& &1.owner_id) |> Enum.uniq()

      candidates =
        Thread
        |> Ash.Query.filter(
          machine_id in ^vm_ids and creator_id in ^owner_ids and status in ^@bound_statuses
        )
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.group_by(& &1.machine_id)

      threads =
        Map.new(vms, fn vm ->
          bound =
            candidates
            |> Map.get(vm.id, [])
            |> Enum.filter(&(&1.creator_id == vm.owner_id))
            |> current_binding()

          {vm.id, bound}
        end)

      thread_ids = for {_, %Thread{id: id}} <- threads, do: id

      grants =
        if thread_ids == [] do
          %{}
        else
          Grant
          |> Ash.Query.filter(thread_id in ^thread_ids and user_id == ^user_id)
          |> Ash.read!(actor: SystemActor.compute())
          |> Enum.group_by(& &1.thread_id)
        end

      DecisionSnapshot.prime(
        Map.merge(
          Map.new(threads, fn {vm_id, thread} -> {{:machine_thread, vm_id}, thread} end),
          Map.new(thread_ids, &{{:thread_grants, &1, user_id}, Map.get(grants, &1, [])})
        )
      )
    end

    :ok
  end

  @spec grants_for(String.t(), String.t()) :: grants()
  defp grants_for(thread_id, user_id) do
    for grant <-
          DecisionSnapshot.fetch({:thread_grants, thread_id, user_id}, fn ->
            Ledger.read!(Grant, thread_id: thread_id, user_id: user_id)
          end),
        into: %{},
        do: {grant.role, [user_id]}
  end

  @spec team_grants(String.t() | nil, String.t()) :: map()
  defp team_grants(nil, _user_id), do: %{}

  defp team_grants(team_id, user_id) do
    if Ledger.read!(Marshall.Teams.Team, id: team_id) != [] and
         Marshall.Teams.member?(team_id, user_id) do
      roles = Marshall.Teams.Coordinator.roles(team_id)
      admins = if user_id in roles.admins or user_id == roles.owner, do: [user_id], else: []
      %{team_admins: admins, team_members: [user_id]}
    else
      %{}
    end
  end
end
