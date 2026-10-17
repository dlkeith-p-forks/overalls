defmodule Marshall.SSH.KeyActions do
  @moduledoc "Owner-scoped key registration shared by the browser and SSH onboarding."
  use Ash.Resource.Actions.Implementation
  alias OverallsProtocol.SSHKey
  alias Marshall.Accounts.AccountLifecycle
  alias Marshall.Compute.Ledger
  alias Marshall.SSH.Key
  require Ash.Query
  require Marshall.Events

  @impl true
  def run(input, options, %{actor: %Marshall.Accounts.User{} = actor}) do
    result =
      Ledger.transaction(fn -> perform(options[:operation], input.arguments, actor) end, actor)

    with {:ok, {value, event}} <- result do
      unless Marshall.Repo.in_transaction?(), do: emit_event(event)
      {:ok, value}
    end
    |> Marshall.SSH.Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  defp perform(:list, _, user) do
    keys =
      Key
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.Query.sort(inserted_at: :desc, id: :asc)
      |> Ash.Query.limit(100)
      |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
      |> Enum.map(&view/1)

    {keys, nil}
  end

  # @cc [owner:ghuntley,label:security;concurrency] key-registration-serialized-owner
  # All registrations MUST serialize both the owner's key limit and the canonical
  # fingerprint. A key held by another account MUST fail without revealing that
  # account; repeated same-owner registration MUST NOT create another identity.

  # @cc [owner:ghuntley,label:security;concurrency] key-registration-retirement-order
  # Registration MUST hold the shared account admission fence and recheck current
  # identity before key locks, through the outer commit, including browser approval.
  # Once retirement wins admission, registration MUST leave keys and audit unchanged.
  defp perform(:add, request, user) do
    parsed =
      case SSHKey.parse(request.public_key) do
        {:ok, parsed} -> parsed
        _ -> Ledger.rollback(:invalid_public_key)
      end

    AccountLifecycle.admit!(user.id)
    lock!("user:" <> user.id)
    lock!("fingerprint:" <> parsed.fingerprint)

    case Ledger.read!(Key, fingerprint: parsed.fingerprint) do
      [%{user_id: id} = key] when id == user.id ->
        {view(key), nil}

      [_] ->
        Ledger.rollback(:key_unavailable)

      [] ->
        count =
          Key
          |> Ash.Query.filter(user_id == ^user.id)
          |> Ash.count!(actor: Marshall.Authorization.SystemActor.compute())

        if count >= 100, do: Ledger.rollback(:key_limit)

        key =
          Key
          |> Ledger.create!(
            :register,
            Map.merge(parsed, %{user_id: user.id, label: request.label})
          )

        {view(key), {:key_added, key.id, user.id}}
    end
  end

  # @cc [owner:ghuntley,label:security] key-removal-owner-check
  # Removing a key MUST verify persisted ownership under a row lock. Revoked key
  # identities MUST remain archived so existing sessions cannot be resurrected.
  defp perform(:remove, %{id: id}, user) do
    case Ledger.lock!(Key, id) do
      %{user_id: owner} = key when owner == user.id ->
        :ok = Ledger.archive!(key, :revoke)
        {%{id: id, revoked: true}, {:key_removed, id, user.id}}

      _ ->
        Ledger.rollback(:key_not_found)
    end
  end

  defp emit_event({:key_added, key_id, user_id}),
    do: Marshall.Events.emit("ssh.key_added", key_id: key_id, user_id: user_id)

  defp emit_event({:key_removed, key_id, user_id}),
    do: Marshall.Events.emit("ssh.key_removed", key_id: key_id, user_id: user_id)

  defp emit_event(nil), do: :ok

  defp lock!(value) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["ssh:" <> value],
      log: false
    )
  end

  @spec view(Key.t()) :: map()
  def view(key), do: Map.take(key, [:id, :label, :algorithm, :fingerprint, :inserted_at])
end
