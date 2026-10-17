defmodule Marshall.Control.Hints do
  @moduledoc """
  Fleet-wide control-plane hints (ADR-0140; control WebSocket plan P0).

  A mutation that can change what a connected party may do or should read
  emits a hint `{kind, id}`. Hints travel over Oban's PostgreSQL notifier,
  whose `pg_notify` runs on the caller's database connection: a hint emitted
  inside a transaction is part of that transaction and is delivered only if it
  commits, to every Marshall node (nodes share PostgreSQL, not Erlang
  distribution).

  A hint is never authority. Every subscriber reacts by re-reading durable
  state through its existing full check, so a duplicate, forged or stale hint
  costs one extra read. A lost hint is caught by each subscriber's backstop,
  and `Relay` forces every local subscriber to resync after the notifier
  recovers from isolation, because Oban signals no reconnect otherwise.
  """

  @channel :control_hints
  @kinds [
    :user,
    :vm,
    :host,
    :service,
    :host_commands,
    :gateway_catalog,
    :dns_snapshot,
    :fleet_certificate,
    :ziggy_work,
    :ssh_session,
    :ssh_approval,
    :endpoint_policy,
    :environment_publication
  ]
  @kind_names Map.new(@kinds, &{Atom.to_string(&1), &1})

  @type kind ::
          :user
          | :vm
          | :host
          | :service
          | :host_commands
          | :gateway_catalog
          | :dns_snapshot
          | :fleet_certificate
          | :ziggy_work
          | :ssh_session
          | :ssh_approval
          | :endpoint_policy
          | :environment_publication

  @doc "The closed set of hint kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The notifier channel hints travel on."
  @spec channel() :: atom()
  def channel, do: @channel

  # @cc [owner:ghuntley,label:security;recovery] control-hint-in-transaction
  # A hint MUST carry only a closed kind and a canonical UUID and MUST be
  # emitted on the caller's database connection, so an uncommitted mutation
  # never notifies. Like any statement of its transaction, a failed pg_notify
  # aborts that transaction; outside a transaction a failure is dropped
  # because every subscriber keeps a backstop read.
  @doc "Emits a hint; invalid identifiers are ignored."
  @spec notify(kind(), String.t() | nil) :: :ok
  def notify(kind, id) when kind in @kinds do
    case is_binary(id) && Ecto.UUID.cast(id) do
      {:ok, id} ->
        Overalls.Diagnostics.Metrics.record([:marshall, :control, :hint], %{count: 1}, %{
          kind: kind,
          id: id
        })

        publish(%{"kind" => Atom.to_string(kind), "id" => id})

      _ ->
        :ok
    end
  end

  @doc "Hints that authority held by this user may have changed."
  @spec notify_user(String.t() | nil) :: :ok
  def notify_user(id), do: notify(:user, id)

  @doc "Hints that authority over or the state of this machine may have changed."
  @spec notify_vm(String.t() | nil) :: :ok
  def notify_vm(id), do: notify(:vm, id)

  @spec publish(map()) :: :ok
  defp publish(payload) do
    if Marshall.Repo.in_transaction?() do
      # Inside a transaction the statement belongs to it (see contract above).
      _ = Oban.Notifier.notify(Oban, @channel, payload)
      :ok
    else
      try do
        _ = Oban.Notifier.notify(Oban, @channel, payload)
        :ok
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  @doc "The user a stored login token belongs to, for token-action hints."
  @spec token_user(%{optional(:subject) => term()}) :: String.t() | nil
  def token_user(%{subject: "user?id=" <> id}), do: id
  def token_user(_token), do: nil

  @doc """
  Subscribes the caller to hints of one kind for one identifier, or with `:all`
  to every hint of that kind (a gateway renewing many streams' leases).
  """
  @spec subscribe(kind(), String.t() | :all) :: :ok | {:error, term()}
  def subscribe(kind, id) when kind in @kinds,
    do: Phoenix.PubSub.subscribe(Marshall.PubSub, topic(kind, id))

  @doc "Subscribes the caller to forced resyncs after notifier recovery."
  @spec subscribe_resync() :: :ok | {:error, term()}
  def subscribe_resync, do: Phoenix.PubSub.subscribe(Marshall.PubSub, "control:resync")

  @doc "Validates a notifier payload and rebroadcasts it on this node."
  @spec deliver(term()) :: :ok | :ignored
  def deliver(%{"kind" => kind, "id" => id}) when is_binary(kind) and is_binary(id) do
    with {:ok, kind} <- Map.fetch(@kind_names, kind),
         {:ok, ^id} <- Ecto.UUID.cast(id) do
      Phoenix.PubSub.local_broadcast(Marshall.PubSub, topic(kind, id), {:control_hint, kind, id})

      Phoenix.PubSub.local_broadcast(
        Marshall.PubSub,
        topic(kind, :all),
        {:control_hint, kind, id}
      )
    else
      _ -> :ignored
    end
  end

  def deliver(_payload), do: :ignored

  @doc "Tells every local subscriber to re-read everything it holds."
  @spec resync_local() :: :ok
  def resync_local,
    do: Phoenix.PubSub.local_broadcast(Marshall.PubSub, "control:resync", :control_resync)

  @spec topic(kind(), String.t() | :all) :: String.t()
  defp topic(kind, :all), do: "control:#{kind}:*"
  defp topic(kind, id), do: "control:#{kind}:#{id}"
end
