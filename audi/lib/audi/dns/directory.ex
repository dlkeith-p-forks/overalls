defmodule Audi.DNS.Directory do
  @moduledoc """
  Atomic local DNS publication replica; never durable domain authority.

  The directory is the single writer (ADR-0140): it validates complete
  snapshots and publishes the accepted one to its `OverallsProtocol.View`.
  Every DNS query is a lock-free view read, so queries never wait behind a
  publish.
  """
  use GenServer
  alias Audi.DNS.Challenge
  alias OverallsProtocol.View
  require Audi.Events

  @type entry ::
          %{required(:addresses) => [:inet.ip_address()], required(:expires_at) => integer()}
          | Challenge.t()
          | %{empty: true}
  @type state :: %{revision: integer(), expires_at: integer(), entries: %{binary() => entry()}}

  @doc "The read view published by the directory registered as `directory`."
  @spec view(atom()) :: atom()
  def view(directory) when is_atom(directory), do: Module.concat(directory, View)

  @doc "Children for a named directory: its read view, then the directory."
  @spec children(keyword()) :: [{module(), keyword()}]
  def children(options) do
    directory = Keyword.fetch!(options, :name)
    [{View, name: view(directory)}, {__MODULE__, options}]
  end

  def start_link(options) do
    name = Keyword.fetch!(options, :name)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  # @cc [owner:ghuntley,label:security;architecture] dns-directory-single-writer
  # The directory MUST be the only writer of its view's :snapshot row and MUST
  # publish only an accepted snapshot; a restart publishes nothing until the
  # replica refreshes, so queries fail closed (SERVFAIL) meanwhile.
  @impl true
  def init(options) do
    view = view(Keyword.fetch!(options, :name))

    case View.claim(view, :snapshot) do
      :ok ->
        {:ok, %{revision: -1, expires_at: 0, entries: %{}, zone: options[:zone], view: view}}

      _ ->
        {:stop, :directory_view_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] dns-snapshot-monotonicity
  # Only trusted control transport may publish complete validated snapshots.
  # Revisions MUST NOT regress. An expired reply MUST NOT refresh the replica.
  # Expiration MUST use the control request's monotonic start, not receipt time.
  # Every route and challenge entry MUST carry its own deadline; a snapshot with
  # any entry lacking one MUST be refused whole.
  @spec publish(GenServer.server(), non_neg_integer(), %{binary() => entry()}, integer()) ::
          :ok | {:error, :stale | :conflict | :invalid_challenge | :invalid_message}
  def publish(server, revision, entries, expires_at)
      when is_integer(revision) and revision >= 0 and is_map(entries) and is_integer(expires_at),
      do: GenServer.call(server, {:publish, revision, entries, expires_at})

  @spec lookup(atom(), binary()) :: {:ok, non_neg_integer(), entry() | nil} | :stale
  def lookup(directory, name) do
    case View.fetch(view(directory), :snapshot) do
      {:ok, {_version, %{revision: revision, expires_at: expires_at, entries: entries}}} ->
        if revision >= 0 and expires_at > now() do
          case live_entry(entries, name) do
            :stale -> :stale
            entry -> {:ok, revision, entry}
          end
        else
          :stale
        end

      :error ->
        :stale
    end
  rescue
    ArgumentError -> :stale
  end

  @impl true
  def handle_call({:publish, revision, entries, expires_at}, _, state) do
    cond do
      Enum.any?(entries, fn {name, entry} ->
        is_map(entry) and Map.has_key?(entry, :challenges) and
            not Challenge.valid?(name, entry, state.zone)
      end) ->
        publish_rejected(:invalid_challenge)
        {:reply, {:error, :invalid_challenge}, state}

      not Enum.all?(entries, fn {_name, entry} -> deadline?(entry) end) ->
        publish_rejected(:invalid_message)
        {:reply, {:error, :invalid_message}, state}

      revision < state.revision or expires_at <= now() ->
        publish_rejected(:stale)
        {:reply, {:error, :stale}, state}

      revision == state.revision and entries != state.entries ->
        publish_rejected(:conflict)
        {:reply, {:error, :conflict}, state}

      true ->
        snapshot = %{revision: revision, entries: entries, expires_at: expires_at}
        {:ok, _version} = View.put(state.view, :snapshot, snapshot)
        {:reply, :ok, Map.merge(state, snapshot)}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] dns-route-independent-expiry
  # A route's deadline MUST remain effective even while the complete snapshot
  # is fresh. Expired route authority MUST produce SERVFAIL, never NXDOMAIN or
  # addresses. Snapshot refresh alone MUST NOT extend a retained route deadline.
  defp live_entry(entries, name) do
    case Map.get(entries, name) do
      %{addresses: _, expires_at: expiry} = entry ->
        if expiry > now(), do: entry, else: :stale

      %{challenges: _} = entry ->
        if Challenge.live?(entry), do: entry

      nil ->
        # A live challenge makes its parent an existing empty non-terminal,
        # even before the VM receives an application address publication.
        case Map.get(entries, "_acme-challenge." <> name) do
          %{challenges: _} = entry -> if Challenge.live?(entry), do: %{empty: true}
          _ -> nil
        end
    end
  end

  # Every route and challenge entry carries its own deadline.
  defp deadline?(%{addresses: addresses, expires_at: expiry}),
    do: is_list(addresses) and is_integer(expiry)

  defp deadline?(%{challenges: _, expires_at: expiry}), do: is_integer(expiry)
  defp deadline?(_), do: false

  defp now, do: System.monotonic_time(:millisecond)

  defp publish_rejected(reason), do: Audi.Events.emit("audi.dns_publish_rejected", reason: reason)
end
