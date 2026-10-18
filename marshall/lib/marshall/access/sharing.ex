defmodule Marshall.Access.Sharing do
  @moduledoc "Transactional sharing, protected ownership, and idempotent role replacement."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Access.{Authorization, Change, Grant}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  require Ash.Query
  require Marshall.Events

  @impl true
  def run(input, options, context) do
    result =
      Ledger.transaction(
        fn ->
          vm = Authorization.live_vm!(input.arguments.vm_id, context.actor, "manage")

          if options[:operation] == :list do
            list(vm, input.arguments)
          else
            change(vm, context.actor, input.arguments)
          end
        end,
        context.actor
      )

    case result do
      {:ok, %Change{} = change} ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("vm.access_changed", vm_id: change.vm_id)
        end

        {:ok, change}

      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end

  # @cc [owner:ghuntley,label:product] sharing-protected-existing-recipient
  # Profiles without sharing capability MUST reject all non-revocation changes before
  # idempotent replay or persistence. Permitted sharing changes MUST resolve an existing
  # account by exact case-insensitive
  # email and MUST NOT replace/revoke the VM owner's ownership. Missing recipients
  # MUST fail without creating users or invitations.

  # @cc [owner:ghuntley,label:recovery] sharing-immutable-retry-result
  # Current profile restrictions MUST be checked before replay. For eligible requests,
  # reusing the same actor/VM/key MUST return its original same-recipient/role
  # change without applying it again; a changed payload MUST conflict. A delayed
  # retry MUST NOT undo a later role replacement or revocation.
  defp change(vm, actor, request) do
    if request.role != :revoked and
         not OverallsProtocol.ProfilePolicy.allows?(vm.profile, :sharing),
       do: Ledger.rollback(:sharing_not_allowed)

    user =
      Marshall.Accounts.User
      |> Ash.Query.for_read(:internal_lookup)
      |> Ash.Query.filter(email == ^request.email)
      |> Ash.read_one!(actor: SystemActor.compute())

    if user == nil, do: Ledger.rollback(:recipient_not_registered)
    if user.id == vm.owner_id, do: Ledger.rollback(:owner_protected)

    case Ledger.read!(Change,
           vm_id: vm.id,
           requested_by_id: actor.id,
           request_key: request.idempotency_key
         ) do
      [existing] ->
        if existing.user_id == user.id and existing.role == request.role,
          do: existing,
          else: Ledger.rollback(:idempotency_conflict)

      [] ->
        grant = replace(vm.id, user.id, actor.id, request.role)
        :ok

        change =
          Ledger.create!(Change, :record, %{
            vm_id: vm.id,
            user_id: user.id,
            requested_by_id: actor.id,
            role: request.role,
            request_key: request.idempotency_key,
            grant_id: if(grant, do: grant.id)
          })

        change
    end
  end

  defp replace(vm_id, user_id, actor_id, role) do
    current = List.first(Ledger.read!(Grant, vm_id: vm_id, user_id: user_id))

    if current != nil and current.role == role do
      current
    else
      if current do
        current
        |> Ledger.update!(:mark_revoked, %{revoked_by_id: actor_id})
        |> Ledger.archive!(:revoke)
      end

      if role != :revoked do
        Ledger.create!(Grant, :grant, %{
          vm_id: vm_id,
          user_id: user_id,
          role: role,
          granted_by_id: actor_id
        })
      end
    end
  end

  defp list(vm, request) do
    query =
      Grant
      |> Ash.Query.filter(vm_id == ^vm.id)
      |> Ash.Query.sort(:id)
      |> Ash.Query.limit(request.limit + 1)

    query =
      if Map.get(request, :after), do: Ash.Query.filter(query, id > ^request.after), else: query

    rows =
      if OverallsProtocol.ProfilePolicy.allows?(vm.profile, :sharing),
        do: Ash.read!(query, actor: SystemActor.compute()),
        else: []

    grants = Enum.take(rows, request.limit)
    ids = [vm.owner_id | Enum.map(grants, & &1.user_id)]

    users =
      Marshall.Accounts.User
      |> Ash.Query.for_read(:internal_lookup)
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(actor: SystemActor.compute())
      |> Map.new(&{&1.id, &1})

    %{
      owner: person(vm.owner_id, users) |> Map.put(:role, :owner),
      items: Enum.map(grants, &Map.merge(person(&1.user_id, users), %{id: &1.id, role: &1.role})),
      next_cursor: if(length(rows) > request.limit, do: List.last(grants).id)
    }
  end

  # Shared people carry their saved zone (ADR-0195) so the Access tab can show
  # their local time; nil means no zone was saved and nothing is shown.
  @spec person(String.t(), %{String.t() => Marshall.Accounts.User.t()}) :: %{
          user_id: String.t(),
          email: String.t() | nil,
          time_zone: String.t() | nil
        }
  defp person(user_id, users) do
    user = users[user_id]
    %{user_id: user_id, email: user && to_string(user.email), time_zone: user && user.time_zone}
  end
end
