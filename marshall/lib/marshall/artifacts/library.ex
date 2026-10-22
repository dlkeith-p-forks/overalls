defmodule Marshall.Artifacts.Library do
  @moduledoc "Cedar-checked artifact reads, listings, deletion and moderation."
  import Ecto.Query
  require Ash.Query
  require Marshall.Events
  alias Marshall.Accounts.User
  alias Marshall.Artifacts.{Artifact, Audit, Authorization, Blobs, Grant, Version, VersionFile}
  alias Marshall.Artifacts.ViewTicket
  alias Marshall.Compute.Ledger

  @type via :: :agent | :web | :admin
  @type page :: %{items: [Artifact.t()], next_cursor: String.t() | nil}

  @doc "The artifact when the actor may read it; unknown and unreadable look the same."
  @spec fetch(String.t(), User.t()) :: {:ok, Artifact.t()} | {:error, :not_found}
  def fetch(id, %User{} = actor) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        case Ledger.read!(Artifact, id: id) do
          [%Artifact{state: :active} = artifact] ->
            if Authorization.allowed?(artifact, actor, :read),
              do: {:ok, artifact},
              else: {:error, :not_found}

          _ ->
            {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def fetch(_, _), do: {:error, :not_found}

  @spec version(Artifact.t(), pos_integer() | nil) :: {:ok, Version.t()} | {:error, :not_found}
  def version(%Artifact{current_version: 0}, _), do: {:error, :not_found}

  def version(%Artifact{} = artifact, number) do
    case Ledger.read!(Version,
           artifact_id: artifact.id,
           number: number || artifact.current_version
         ) do
      [%Version{} = version] -> {:ok, version}
      [] -> {:error, :not_found}
    end
  end

  @spec versions(Artifact.t()) :: [Version.t()]
  def versions(%Artifact{} = artifact) do
    Version
    |> Ash.Query.filter(artifact_id == ^artifact.id)
    |> Ash.Query.sort(number: :desc)
    |> Ash.Query.limit(200)
    |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
  end

  @spec files(Version.t()) :: [VersionFile.t()]
  def files(%Version{} = version),
    do: Ledger.read!(VersionFile, version_id: version.id) |> Enum.sort_by(& &1.path)

  @doc "The page source of a version (bounded at 16 MiB by the publish limits)."
  @spec page(Version.t()) :: binary()
  def page(%Version{page_sha256: sha}), do: Blobs.read!(sha)

  # @cc [owner:ghuntley,label:security] artifact-list-cedar
  # Listings MUST contain only active artifacts the actor can read now: owned,
  # directly granted, or granted to a team the actor currently belongs to, each
  # rechecked with Cedar. The title search is literal.
  @spec list(User.t(), %{
          optional(:query) => String.t() | nil,
          optional(:after) => String.t() | nil,
          optional(:limit) => pos_integer()
        }) :: page()
  def list(%User{} = actor, options \\ %{}) do
    limit = min(options[:limit] || 50, 100)
    team_ids = team_ids(actor.id)

    query =
      from(a in "artifacts",
        as: :artifact,
        where: a.state == "active",
        where:
          a.owner_id == type(^actor.id, :binary_id) or
            exists(
              from(g in "artifact_grants",
                where:
                  g.artifact_id == parent_as(:artifact).id and is_nil(g.archived_at) and
                    (g.user_id == type(^actor.id, :binary_id) or
                       g.team_id in type(^team_ids, {:array, :binary_id})),
                select: 1
              )
            ),
        order_by: [desc: a.updated_at, desc: a.id],
        select: %{id: type(a.id, :binary_id), updated_at: a.updated_at}
      )
      |> narrow_query(options[:query])
      |> after_cursor(options[:after])

    rows = Marshall.Repo.all(from(q in query, limit: ^(limit + 1)))
    ids = rows |> Enum.take(limit) |> Enum.map(& &1.id)

    by_id = Map.new(Ledger.read!(Artifact, id: [in: ids]), &{&1.id, &1})

    items =
      ids
      |> Enum.map(&Map.get(by_id, &1))
      |> Enum.filter(&(&1 && Authorization.allowed?(&1, actor, :read)))

    %{items: items, next_cursor: if(length(rows) > limit, do: List.last(ids))}
  end

  @spec team_ids(String.t()) :: [String.t()]
  defp team_ids(user_id) do
    member = Ledger.read!(Marshall.Teams.TeamMember, user_id: user_id) |> Enum.map(& &1.team_id)
    Ledger.read!(Marshall.Teams.Team, id: [in: member]) |> Enum.map(& &1.id)
  end

  defp narrow_query(query, nil), do: query

  defp narrow_query(query, text) do
    pattern = "%" <> Marshall.Threads.Coordinator.escape_like(text) <> "%"
    from(a in query, where: fragment("? ILIKE ? ESCAPE '\\'", a.title, ^pattern))
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, cursor) do
    case Ecto.UUID.cast(cursor) do
      {:ok, id} ->
        case Ledger.read!(Artifact, id: id) do
          [%Artifact{updated_at: at}] ->
            from(a in query,
              where: a.updated_at < ^at or (a.updated_at == ^at and a.id < type(^id, :binary_id))
            )

          _ ->
            from(a in query, where: false)
        end

      :error ->
        from(a in query, where: false)
    end
  end

  # @cc [owner:ghuntley,label:security;durability] artifact-delete
  # Owner deletion requires Cedar delete; moderation requires an elevated
  # administrator, Cedar admin delete and a closed moderation reason, and never
  # grants content access. Both move active -> deleting, revoke every issued
  # view ticket, write one audit row in the same transaction and enqueue the
  # purge. Repeating a delete of a deleting or deleted artifact is a no-op for
  # its owner (or an elevated administrator for moderation) and `not_found`
  # for everyone else, so a repeat never reveals metadata to another user.
  @spec delete(User.t(), String.t(), via()) :: {:ok, Artifact.t()} | {:error, atom()}
  def delete(%User{} = actor, id, via) when via in [:agent, :web] do
    repeat? = fn artifact -> artifact.owner_id == actor.id end

    transition(actor, id, repeat?, fn artifact ->
      Authorization.require!(artifact, actor, :delete)

      artifact
      |> Ledger.update!(:request_delete, %{})
      |> tap(fn deleted ->
        Audit.record!(%{artifact_id: deleted.id, actor_id: actor.id, kind: :deleted, via: via})

        Ledger.after_commit(fn ->
          Marshall.Events.emit("artifact.deleted", artifact_id: deleted.id, via: via)
        end)
      end)
    end)
  end

  @spec admin_delete(User.t(), String.t(), atom()) :: {:ok, Artifact.t()} | {:error, atom()}
  def admin_delete(%User{} = actor, id, reason)
      when reason in [:abuse, :legal, :security, :owner_request, :other] do
    repeat? = fn _artifact ->
      actor.administrator and Marshall.Accounts.Security.recent?(actor)
    end

    transition(actor, id, repeat?, fn artifact ->
      Authorization.require!(artifact, actor, :admin_delete)

      artifact
      |> Ledger.update!(:admin_delete, %{moderation_reason: reason})
      |> tap(fn deleted ->
        Audit.record!(%{
          artifact_id: deleted.id,
          actor_id: actor.id,
          kind: :admin_deleted,
          via: :admin,
          reason: reason
        })

        Ledger.create!(Marshall.Administration.AuditEvent, :record, %{
          actor_id: actor.id,
          request_id: Ash.UUID.generate(),
          action: :artifact_admin_delete,
          resource_type: :artifact,
          resource_id: deleted.id
        })

        Ledger.after_commit(fn ->
          Marshall.Events.emit("artifact.admin_deleted", artifact_id: deleted.id, reason: reason)
        end)
      end)
    end)
  end

  def admin_delete(_, _, _), do: {:error, :invalid_reason}

  @spec transition(
          User.t(),
          String.t(),
          (Artifact.t() -> boolean()),
          (Artifact.t() -> Artifact.t())
        ) :: {:ok, Artifact.t()} | {:error, atom()}
  defp transition(actor, id, repeat?, fun) do
    Ledger.transaction(
      fn ->
        case Ecto.UUID.cast(id) do
          {:ok, id} ->
            case Ledger.lock!(Artifact, id) do
              %Artifact{state: :active} = artifact ->
                deleted = fun.(artifact)
                revoke_tickets!(deleted.id)

                %{"artifact_id" => deleted.id}
                |> Marshall.Artifacts.PurgeJob.new()
                |> Oban.insert!()

                deleted

              %Artifact{} = artifact ->
                if repeat?.(artifact), do: artifact, else: Ledger.rollback(:not_found)

              nil ->
                Ledger.rollback(:not_found)
            end

          :error ->
            Ledger.rollback(:not_found)
        end
      end,
      {:user, actor.id}
    )
  end

  @doc "Revokes every issued ticket for an artifact; callers hold the artifact lock."
  @spec revoke_tickets!(String.t()) :: :ok
  def revoke_tickets!(artifact_id) do
    ViewTicket
    |> Ash.Query.filter(artifact_id == ^artifact_id and state == :issued)
    |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
    |> Enum.each(&Ledger.update!(&1, :revoke, %{}))
  end

  @doc "Revokes one user's issued tickets after their access changed."
  @spec revoke_user_tickets!(String.t(), String.t() | nil) :: :ok
  def revoke_user_tickets!(artifact_id, nil), do: revoke_tickets!(artifact_id)

  def revoke_user_tickets!(artifact_id, user_id) do
    ViewTicket
    |> Ash.Query.filter(artifact_id == ^artifact_id and user_id == ^user_id and state == :issued)
    |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
    |> Enum.each(&Ledger.update!(&1, :revoke, %{}))
  end

  @doc "Grants visible to a reader managing sharing."
  @spec grants(Artifact.t()) :: [Grant.t()]
  def grants(%Artifact{} = artifact),
    do: Ledger.read!(Grant, artifact_id: artifact.id) |> Enum.sort_by(&{&1.inserted_at, &1.id})

  @doc "Current grants with a display label: the user's email or the team's name."
  @spec labelled_grants(Artifact.t()) :: [{Grant.t(), String.t()}]
  def labelled_grants(%Artifact{} = artifact) do
    for grant <- grants(artifact), label = grant_label(grant), do: {grant, label}
  end

  @spec grant_label(Grant.t()) :: String.t() | nil
  defp grant_label(%Grant{user_id: user_id}) when is_binary(user_id) do
    case Marshall.Accounts.Security.current(user_id) do
      %User{deleted_at: nil, email: email} -> to_string(email)
      _ -> nil
    end
  end

  defp grant_label(%Grant{team_id: team_id}) when is_binary(team_id) do
    case Ledger.read!(Marshall.Teams.Team, id: team_id) do
      [%{name: name}] -> name
      _ -> nil
    end
  end
end
