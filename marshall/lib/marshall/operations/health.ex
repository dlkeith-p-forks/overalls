defmodule Marshall.Operations.Health do
  @moduledoc """
  Bounded readiness for a writable, migrated database. Diagnostics contain no data.

  ADR-0140: a definite answer (read-only, missing migration, a database error)
  acts at once. No answer at all (a saturated pool, a lost connection, a
  timeout) is inconclusive: it keeps the last ready verdict for at most
  `backstop_ms/0`, so contention on a shared database cannot remove every node
  from the load balancer at once.
  """

  @backstop_ms 30_000
  @key {__MODULE__, :last_ready}

  @type observation :: :ready | :not_ready | :inconclusive

  @spec backstop_ms() :: pos_integer()
  def backstop_ms, do: @backstop_ms

  @doc "Creates the last-ready cell; called once at application start."
  @spec install() :: :ok
  def install do
    unless match?({:ok, _}, cell()), do: :persistent_term.put(@key, :atomics.new(1, signed: true))
    :ok
  end

  # @cc [owner:ghuntley,label:recovery] health-writable-migrated-database
  # Readiness MUST require a writable primary with the release's latest required
  # migration. Its query MUST have a 500ms timeout with queueing disabled; missing
  # schema, read-only state or database errors MUST return false without logging
  # query/payload diagnostics. Only an unanswered query (no connection, timeout or
  # exit) is inconclusive and MAY keep a ready verdict observed within the backstop.
  @spec ready?() :: boolean()
  def ready? do
    now = System.monotonic_time(:millisecond)
    {verdict, last} = decide(last_ready(), observe(), now)
    remember(last)
    verdict
  end

  # @cc [owner:ghuntley,label:recovery] health-inconclusive-backstop
  # :ready MUST record now and answer true; :not_ready MUST clear the record and
  # answer false; :inconclusive MUST answer true only within the backstop of the
  # last ready observation and never extends it.
  @doc "Pure readiness decision from the last ready time, an observation and now."
  @spec decide(integer() | nil, observation(), integer()) :: {boolean(), integer() | nil}
  def decide(_last, :ready, now), do: {true, now}
  def decide(_last, :not_ready, _now), do: {false, nil}
  def decide(nil, :inconclusive, _now), do: {false, nil}
  def decide(last, :inconclusive, now), do: {now - last < @backstop_ms, last}

  @spec observe() :: observation()
  defp observe do
    case Ecto.Adapters.SQL.query(
           Marshall.Repo,
           """
           SELECT NOT pg_is_in_recovery()
             AND current_setting('transaction_read_only') = 'off'
             AND EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)
           """,
           [required_version()],
           timeout: 500,
           queue: false,
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> :ready
      {:error, %DBConnection.ConnectionError{}} -> :inconclusive
      _ -> :not_ready
    end
  rescue
    _ in [DBConnection.ConnectionError, DBConnection.OwnershipError] -> :inconclusive
    _ -> :not_ready
  catch
    :exit, _ -> :inconclusive
  end

  @spec last_ready() :: integer() | nil
  defp last_ready do
    case cell() do
      {:ok, ref} ->
        case :atomics.get(ref, 1) do
          0 -> nil
          value -> value
        end

      :error ->
        nil
    end
  end

  @spec remember(integer() | nil) :: :ok
  defp remember(value) do
    with {:ok, ref} <- cell(), do: :atomics.put(ref, 1, value || 0)
    :ok
  end

  @spec cell() :: {:ok, :atomics.atomics_ref()} | :error
  defp cell do
    case :persistent_term.get(@key, nil) do
      nil -> :error
      ref -> {:ok, ref}
    end
  end

  @spec required_version() :: pos_integer()
  def required_version do
    Application.app_dir(:marshall, "priv/repo/migrations/*.exs")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path |> Path.basename() |> String.split("_", parts: 2) |> hd() |> String.to_integer()
    end)
    |> Enum.max()
  end
end
