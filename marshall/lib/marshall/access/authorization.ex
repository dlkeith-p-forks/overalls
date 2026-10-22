defmodule Marshall.Access.Authorization do
  @moduledoc """
  Fresh persisted membership mapped into the real Cedar VM policy. No permission
  cache: persisted inputs are reused only within one DecisionSnapshot batch.
  """
  alias Marshall.Access.Grant
  alias Marshall.Authorization.{Cedar, DecisionSnapshot, SystemActor}
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
        DecisionSnapshot.fetch({:user, vm.owner_id}, fn ->
          Marshall.Accounts.Security.current(vm.owner_id)
        end)
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
  # grants MUST confer no authority. Caller-supplied roles or entities cached
  # outside the current DecisionSnapshot batch MUST NOT contribute membership to
  # a new authorization decision.
  @spec entity(VirtualMachine.t(), Marshall.Accounts.User.t()) :: ExCedar.Entity.t()
  def entity(vm, %Marshall.Accounts.User{id: id} = actor) do
    DecisionSnapshot.fetch({:vm_entity, vm.id, id}, fn -> fresh_entity(vm, actor) end)
  end

  @doc "Batch the actor's machine grant and team membership reads for a page of VMs."
  @spec prefetch([VirtualMachine.t()], Marshall.Accounts.User.t()) :: :ok
  def prefetch(vms, %Marshall.Accounts.User{id: id} = actor) do
    if DecisionSnapshot.active?() and vms != [] do
      vm_ids = Enum.map(vms, & &1.id)
      team_ids = vms |> Enum.map(& &1.team_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      grants =
        Grant
        |> Ash.Query.filter(vm_id in ^vm_ids and user_id == ^id)
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.group_by(& &1.vm_id)

      memberships =
        if team_ids == [] do
          %{}
        else
          Marshall.Teams.TeamMember
          |> Ash.Query.filter(team_id in ^team_ids and user_id == ^id)
          |> Ash.read!(actor: SystemActor.compute())
          |> Enum.group_by(& &1.team_id)
        end

      DecisionSnapshot.prime(
        Map.merge(
          Map.new(vm_ids, &{{:vm_grants, &1, id}, Map.get(grants, &1, [])}),
          Map.new(team_ids, &{{:team_membership, &1, id}, Map.get(memberships, &1, [])})
        )
      )

      Marshall.Threads.Authorization.prefetch(vms, actor)
    end

    :ok
  end

  defp fresh_entity(vm, %Marshall.Accounts.User{id: id} = actor) do
    grants =
      for grant <-
            DecisionSnapshot.fetch({:vm_grants, vm.id, id}, fn ->
              Ledger.read!(Grant, vm_id: vm.id, user_id: id)
            end),
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
    case DecisionSnapshot.fetch({:team_membership, team_id, id}, fn ->
           Ledger.read!(Marshall.Teams.TeamMember, team_id: team_id, user_id: id)
         end) do
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
