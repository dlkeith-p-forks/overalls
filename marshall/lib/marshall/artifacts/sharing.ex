defmodule Marshall.Artifacts.Sharing do
  @moduledoc "Owner-managed artifact roles for users (by email) and teams."
  require Ash.Query
  require Marshall.Events
  alias Marshall.Accounts.User
  alias Marshall.Artifacts.{AccessChange, Artifact, Audit, Authorization, Grant, Library}
  alias Marshall.Compute.Ledger

  @type subject :: {:email, String.t()} | {:team, String.t()}
  @type role :: :owner | :writer | :viewer | :revoked

  # @cc [owner:ghuntley,label:security;durability] artifact-sharing
  # Changing access requires Cedar share on an active artifact. The immutable
  # owner's role cannot change; teams may hold writer or viewer only. Each
  # change archives the previous grant, writes one access-change receipt (once
  # per request key) and one audit row in the same transaction, and revokes the
  # affected user's (or, for teams, every) issued view ticket.
  @spec set_access(User.t(), String.t(), subject(), role(), String.t()) ::
          {:ok, AccessChange.t()} | {:error, atom()}
  def set_access(%User{} = actor, artifact_id, subject, role, request_key)
      when role in [:owner, :writer, :viewer, :revoked] and is_binary(request_key) and
             byte_size(request_key) in 1..128 do
    Ledger.transaction(
      fn ->
        artifact = Ledger.lock!(Artifact, artifact_id) || Ledger.rollback(:not_found)
        unless Authorization.allowed?(artifact, actor, :read), do: Ledger.rollback(:not_found)
        Authorization.require!(artifact, actor, :share)

        case Ledger.read!(AccessChange,
               artifact_id: artifact.id,
               requested_by_id: actor.id,
               request_key: request_key
             ) do
          [change] -> change
          [] -> apply_change!(actor, artifact, resolve!(subject, role), role, request_key)
        end
      end,
      {:user, actor.id}
    )
  end

  def set_access(_, _, _, _, _), do: {:error, :invalid_request}

  @spec resolve!(subject(), role()) :: {:user, String.t()} | {:team, String.t()}
  defp resolve!({:email, email}, _role) do
    case Ash.read_one(
           Ash.Query.filter(
             Ash.Query.for_read(User, :internal_lookup, %{},
               actor: Marshall.Authorization.SystemActor.compute()
             ),
             email == ^email and is_nil(deleted_at)
           )
         ) do
      {:ok, %User{id: id}} -> {:user, id}
      _ -> Ledger.rollback(:not_found)
    end
  end

  defp resolve!({:team, team_id}, role) when role in [:writer, :viewer, :revoked] do
    case Ledger.read!(Marshall.Teams.Team, id: team_id) do
      [_team] -> {:team, team_id}
      [] -> Ledger.rollback(:not_found)
    end
  end

  defp resolve!(_, _), do: Ledger.rollback(:invalid_role)

  defp apply_change!(actor, artifact, {kind, id} = subject, role, request_key) do
    if kind == :user and id == artifact.owner_id, do: Ledger.rollback(:owner_immutable)

    current =
      case subject do
        {:user, user_id} -> Ledger.read!(Grant, artifact_id: artifact.id, user_id: user_id)
        {:team, team_id} -> Ledger.read!(Grant, artifact_id: artifact.id, team_id: team_id)
      end

    Enum.each(current, &Ledger.archive!(&1, :revoke))

    grant =
      if role != :revoked do
        Ledger.create!(Grant, :grant, %{
          artifact_id: artifact.id,
          user_id: if(kind == :user, do: id),
          team_id: if(kind == :team, do: id),
          role: role,
          granted_by_id: actor.id
        })
      end

    Library.revoke_user_tickets!(artifact.id, if(kind == :user, do: id))

    change =
      Ledger.create!(AccessChange, :record, %{
        artifact_id: artifact.id,
        requested_by_id: actor.id,
        user_id: if(kind == :user, do: id),
        team_id: if(kind == :team, do: id),
        role: role,
        request_key: request_key,
        grant_id: grant && grant.id
      })

    Audit.record!(%{
      artifact_id: artifact.id,
      actor_id: actor.id,
      kind: if(role == :revoked, do: :unshared, else: :shared),
      via: :web
    })

    Ledger.after_commit(fn ->
      Marshall.Events.emit("artifact.access_changed",
        artifact_id: artifact.id,
        operation: if(role == :revoked, do: :revoked, else: role)
      )
    end)

    change
  end
end
