defmodule Marshall.Threads.Authorization do
  @moduledoc "Fresh thread ACLs and their inherited authority on the current work machine."
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Authorization.{Cedar, SystemActor}
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

  @spec machine_thread(VirtualMachine.t()) :: Thread.t() | nil
  defp machine_thread(vm) do
    if OverallsProtocol.ProfilePolicy.allows?(vm.profile, :sharing) and is_nil(vm.archived_at) do
      Thread
      |> Ash.Query.filter(
        machine_id == ^vm.id and creator_id == ^vm.owner_id and
          status in [:pending, :provisioning, :ready, :failed, :deleting]
      )
      |> Ash.Query.limit(2)
      |> Ash.read!(actor: SystemActor.compute())
      |> case do
        [thread] -> if shareable?(thread), do: thread
        _ -> nil
      end
    end
  end

  @spec grants_for(String.t(), String.t()) :: grants()
  defp grants_for(thread_id, user_id) do
    for grant <- Ledger.read!(Grant, thread_id: thread_id, user_id: user_id),
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
