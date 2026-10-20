defmodule Marshall.Access.Authorization do
  @moduledoc "Fresh persisted membership mapped into the real Cedar VM policy. No permission cache."
  alias Marshall.Access.Grant
  alias Marshall.Authorization.{Cedar, SystemActor}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  require Ash.Query

  # @cc [owner:ghuntley,label:security] customer-owner-only-access
  # Customer VM access MUST require the immutable owner, even for administrators,
  # and MUST deny web access. Unknown profiles MUST deny. Cedar remains required.
  # A machine whose owner is retired or SCIM-inactive MUST deny every actor, so
  # collaborators cannot wake a SCIM-suspended machine during the grace period.
  @spec allowed?(VirtualMachine.t(), term(), String.t()) :: boolean()
  def allowed?(vm, %Marshall.Accounts.User{} = actor, action) do
    OverallsProtocol.ProfilePolicy.allows?(vm.profile, :terminal) and
      (vm.owner_id == actor.id or OverallsProtocol.ProfilePolicy.allows?(vm.profile, :sharing)) and
      (action != "web" or OverallsProtocol.ProfilePolicy.allows?(vm.profile, :web)) and
      match?(
        %Marshall.Accounts.User{deleted_at: nil, active: true},
        Marshall.Accounts.Security.current(vm.owner_id)
      ) and
      Cedar.allowed?(actor, action, entity(vm, actor))
  end

  def allowed?(_, _, _), do: false

  # @cc [owner:ghuntley,label:security] access-fresh-cedar-entity
  # Each VM entity MUST contain its immutable owner, the actor's current
  # unarchived machine and currently bound thread grants read from PostgreSQL
  # only when the profile permits sharing, and the actor's current team
  # memberships when the machine belongs to a team. These sources are additive;
  # reducing one source MUST NOT erase independent authority from another. Customer
  # grants MUST confer no authority. Caller-supplied roles or stale entity
  # caches MUST NOT contribute membership to a new authorization decision.
  @spec entity(VirtualMachine.t(), Marshall.Accounts.User.t()) :: ExCedar.Entity.t()
  def entity(vm, %Marshall.Accounts.User{id: id} = actor) do
    grants =
      for grant <- Ledger.read!(Grant, vm_id: vm.id, user_id: id),
          OverallsProtocol.ProfilePolicy.allows?(vm.profile, :sharing),
          into: %{},
          do: {grant.role, [id]}

    grants =
      grants
      |> Map.merge(Marshall.Threads.Authorization.machine_grants(vm, actor), fn _role,
                                                                                left,
                                                                                right ->
        Enum.uniq(left ++ right)
      end)
      |> Map.merge(team_grants(vm, id))

    Cedar.vm(vm.id, vm.owner_id, grants)
  end

  defp team_grants(%VirtualMachine{team_id: nil}, _id), do: %{}

  defp team_grants(%VirtualMachine{team_id: team_id}, id) do
    case Ledger.read!(Marshall.Teams.TeamMember, team_id: team_id, user_id: id) do
      [membership] ->
        admins = if membership.role in [:owner, :admin], do: [id], else: []
        %{team_admins: admins, team_members: [id]}

      [] ->
        %{}
    end
  end

  @spec require!(VirtualMachine.t(), term(), String.t()) :: :ok
  def require!(vm, actor, action) do
    unless allowed?(vm, actor, action), do: Ledger.rollback(:forbidden)
    :ok
  end

  # @cc [owner:ghuntley,label:security] access-administrative-lease-deadline
  # Leases relying on administrator override MUST NOT outlive the fixed passkey
  # deadline. Ordinary owner/sharing rights MUST retain their normal lifetime.
  @spec deadline!(VirtualMachine.t(), Marshall.Accounts.User.t(), String.t(), DateTime.t()) ::
          DateTime.t()
  def deadline!(vm, actor, action, maximum) do
    require!(vm, actor, action)

    if allowed?(vm, %Marshall.Accounts.User{id: actor.id}, action) do
      maximum
    else
      expiry = Marshall.Accounts.Security.elevated_until(actor) || Ledger.rollback(:mfa_required)
      if DateTime.compare(expiry, maximum) == :lt, do: expiry, else: maximum
    end
  end

  @doc "The VM row serializes access mutation with lifecycle. Never acquire its host lock afterward."
  @spec live_vm!(String.t(), term(), String.t(), boolean(), boolean()) :: VirtualMachine.t()
  def live_vm!(id, actor, action, lock \\ true, allow_deleting \\ false) do
    query = VirtualMachine |> Ash.Query.filter(id == ^id)
    query = if lock, do: Ash.Query.lock(query, :for_update), else: query
    vm = Ash.read_one!(query, actor: SystemActor.compute()) || Ledger.rollback(:forbidden)
    require!(vm, actor, action)
    if vm.desired_state == :deleted and not allow_deleting, do: Ledger.rollback(:vm_deleted)
    vm
  end
end
