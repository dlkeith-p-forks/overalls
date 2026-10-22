defmodule Marshall.Artifacts.Storage do
  @moduledoc """
  Page storage reached only through Marshall's postMessage bridge. `personal`
  keys belong to the viewing user; `shared` keys belong to the artifact and
  only writers and owners can change them.
  """
  require Ash.Query
  require Marshall.Events
  alias Marshall.Accounts.User
  alias Marshall.Artifacts.{Artifact, Audit, Authorization, Limits, StorageEntry, StorageUsage}
  alias Marshall.Compute.Ledger

  @type namespace :: :personal | :shared
  @type refusal :: :forbidden | :not_found | :quota_exceeded | :invalid_key | :invalid_value

  @list_limit 100

  @spec get(User.t(), String.t(), namespace(), String.t()) ::
          {:ok, String.t() | nil} | {:error, refusal()}
  def get(actor, artifact_id, namespace, key) do
    with {:ok, artifact} <- readable(actor, artifact_id, namespace, :read),
         :ok <- valid_key(key) do
      case Ledger.read!(StorageEntry,
             artifact_id: artifact.id,
             namespace: namespace,
             scope_id: scope(artifact, actor, namespace),
             key: key
           ) do
        [entry] -> {:ok, entry.value}
        [] -> {:ok, nil}
      end
    end
  end

  @spec list(User.t(), String.t(), namespace(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, refusal()}
  def list(actor, artifact_id, namespace, prefix) do
    with {:ok, artifact} <- readable(actor, artifact_id, namespace, :read) do
      scope = scope(artifact, actor, namespace)

      keys =
        StorageEntry
        |> Ash.Query.filter(
          artifact_id == ^artifact.id and namespace == ^namespace and scope_id == ^scope
        )
        |> Ash.Query.sort(key: :asc)
        |> Ash.Query.limit(1_000)
        |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
        |> Enum.map(& &1.key)
        |> Enum.filter(&(is_nil(prefix) or String.starts_with?(&1, prefix)))
        |> Enum.take(@list_limit)

      {:ok, keys}
    end
  end

  # @cc [owner:ghuntley,label:security;capacity] artifact-storage-namespaces
  # Personal storage is keyed by (artifact, user) and needs Cedar personal
  # storage; shared storage is keyed by the artifact, reading needs shared read
  # and writing needs shared write (writers and owners only). Each scope holds
  # at most 20 MiB of UTF-8 text including keys, enforced under the usage row
  # lock; a refusal changes nothing. Values are never logged.
  @spec put(User.t(), String.t(), namespace(), String.t(), String.t()) ::
          :ok | {:error, refusal()}
  def put(actor, artifact_id, namespace, key, value) do
    with :ok <- valid_key(key),
         :ok <- valid_value(value) do
      mutate(actor, artifact_id, namespace, fn artifact, scope, usage ->
        existing = entry(artifact, namespace, scope, key)
        size = byte_size(key) + byte_size(value)
        delta = size - if(existing, do: existing.bytes, else: 0)
        if usage.bytes + delta > Limits.storage_bytes(), do: Ledger.rollback(:quota_exceeded)

        if existing do
          Ledger.update!(existing, :replace, %{value: value, bytes: size, updated_by_id: actor.id})
        else
          Ledger.create!(StorageEntry, :put, %{
            artifact_id: artifact.id,
            namespace: namespace,
            scope_id: scope,
            key: key,
            value: value,
            bytes: size,
            updated_by_id: actor.id
          })
        end

        Ledger.update!(usage, :adjust, %{
          bytes: usage.bytes + delta,
          entries: usage.entries + if(existing, do: 0, else: 1)
        })

        {:storage_written, size}
      end)
    end
  end

  @spec delete(User.t(), String.t(), namespace(), String.t()) :: :ok | {:error, refusal()}
  def delete(actor, artifact_id, namespace, key) do
    with :ok <- valid_key(key) do
      mutate(actor, artifact_id, namespace, fn artifact, scope, usage ->
        case entry(artifact, namespace, scope, key) do
          nil ->
            {:storage_deleted, 0}

          existing ->
            Ash.destroy!(existing, actor: Marshall.Authorization.SystemActor.compute())

            Ledger.update!(usage, :adjust, %{
              bytes: max(usage.bytes - existing.bytes, 0),
              entries: max(usage.entries - 1, 0)
            })

            {:storage_deleted, existing.bytes}
        end
      end)
    end
  end

  @spec mutate(User.t(), String.t(), namespace(), (Artifact.t(), String.t(), StorageUsage.t() ->
                                                     {atom(), non_neg_integer()})) ::
          :ok | {:error, refusal()}
  defp mutate(actor, artifact_id, namespace, fun) do
    action = if namespace == :shared, do: :storage_shared_write, else: :storage_personal

    result =
      Ledger.transaction(
        fn ->
          artifact = Ledger.lock!(Artifact, artifact_id) || Ledger.rollback(:not_found)
          unless Authorization.allowed?(artifact, actor, :read), do: Ledger.rollback(:not_found)
          Authorization.require!(artifact, actor, action)
          scope = scope(artifact, actor, namespace)
          usage = usage!(artifact, namespace, scope)
          {kind, bytes} = fun.(artifact, scope, usage)

          Audit.record!(%{
            artifact_id: artifact.id,
            actor_id: actor.id,
            kind: kind,
            via: :web,
            bytes: bytes
          })

          bytes
        end,
        {:user, actor.id}
      )

    case result do
      {:ok, bytes} ->
        Overalls.Diagnostics.Metrics.record(
          [:marshall, :artifacts, :storage],
          %{bytes: bytes, refused: false},
          %{namespace: namespace}
        )

        :ok

      {:error, reason} ->
        reason =
          if reason in [:forbidden, :not_found, :quota_exceeded], do: reason, else: :forbidden

        if reason != :not_found do
          Audit.refusal(%{
            artifact_id: artifact_id,
            actor_id: actor.id,
            kind: :storage_refused,
            via: :web,
            reason: reason
          })

          Marshall.Events.emit("artifact.storage_refused",
            artifact_id: artifact_id,
            namespace: namespace,
            reason: reason
          )
        end

        Overalls.Diagnostics.Metrics.record(
          [:marshall, :artifacts, :storage],
          %{bytes: 0, refused: true},
          %{namespace: namespace}
        )

        {:error, reason}
    end
  end

  @spec readable(User.t(), String.t(), namespace(), :read) ::
          {:ok, Artifact.t()} | {:error, refusal()}
  defp readable(actor, artifact_id, namespace, :read) do
    action = if namespace == :shared, do: :storage_shared_read, else: :storage_personal

    with {:ok, artifact} <- Marshall.Artifacts.Library.fetch(artifact_id, actor) do
      if Authorization.allowed?(artifact, actor, action),
        do: {:ok, artifact},
        else: {:error, :forbidden}
    end
  end

  @spec scope(Artifact.t(), User.t(), namespace()) :: String.t()
  defp scope(_artifact, actor, :personal), do: actor.id
  defp scope(artifact, _actor, :shared), do: artifact.id

  @spec entry(Artifact.t(), namespace(), String.t(), String.t()) :: StorageEntry.t() | nil
  defp entry(artifact, namespace, scope, key) do
    case Ledger.read!(StorageEntry,
           artifact_id: artifact.id,
           namespace: namespace,
           scope_id: scope,
           key: key
         ) do
      [entry] -> entry
      [] -> nil
    end
  end

  @spec usage!(Artifact.t(), namespace(), String.t()) :: StorageUsage.t()
  defp usage!(artifact, namespace, scope) do
    case Ledger.read!(StorageUsage,
           artifact_id: artifact.id,
           namespace: namespace,
           scope_id: scope
         ) do
      [usage] ->
        Ledger.lock!(StorageUsage, usage.id)

      [] ->
        Ledger.create!(StorageUsage, :open, %{
          artifact_id: artifact.id,
          namespace: namespace,
          scope_id: scope
        })
    end
  end

  @spec valid_key(term()) :: :ok | {:error, :invalid_key}
  def valid_key(key) when is_binary(key) do
    if byte_size(key) in 1..Limits.storage_key_bytes() and String.valid?(key) and
         not String.contains?(key, <<0>>),
       do: :ok,
       else: {:error, :invalid_key}
  end

  def valid_key(_), do: {:error, :invalid_key}

  @spec valid_value(term()) :: :ok | {:error, :invalid_value}
  def valid_value(value) when is_binary(value) do
    if byte_size(value) <= 5_242_880 and String.valid?(value) and
         not String.contains?(value, <<0>>),
       do: :ok,
       else: {:error, :invalid_value}
  end

  def valid_value(_), do: {:error, :invalid_value}
end
