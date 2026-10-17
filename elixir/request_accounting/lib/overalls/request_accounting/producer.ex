defmodule Overalls.RequestAccounting.Producer do
  @moduledoc """
  Supervised source-local producer with durable recording-gap recovery.

  Applications admit eligible work before execution, retain the returned ticket
  and complete it once. Only the admitting process or its named local worker may
  complete a ticket. Measurement failures preserve application execution while
  recording incomplete coverage independently.
  """
  alias Overalls.RequestAccounting.Config
  alias Overalls.RequestAccounting.Producer.Server

  @max_counter 9_223_372_036_854_775_807

  @typedoc "An acknowledged durable admission, or an unavailable measurement."
  @type ticket :: reference() | :unrecorded
  @type outcome :: :success | :failure | :exclude
  @doc "Returns a supervision child specification for a validated producer."
  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    config = Config.validate!(config)
    %{id: config.name, start: {__MODULE__, :start_link, [config]}, shutdown: 10_000}
  end

  @doc "Returns the configured producer child, or an empty list when disabled."
  @spec children(atom()) :: [{module(), Config.t()}]
  def children(name) do
    case Config.from_environment(name) do
      :ignore ->
        []

      {:ok, config} ->
        [{__MODULE__, config}]

      {:error, :invalid_measurement_configuration} ->
        raise ArgumentError, "invalid request accounting configuration"
    end
  end

  @doc "Starts a producer from explicit validated configuration."
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    case Config.validate(config) do
      {:ok, config} -> GenServer.start_link(Server, config, name: config.name)
      {:error, reason} -> {:error, reason}
    end
  end

  # @cc [owner:ghuntley,label:reliability;security] producer-admit-before-eligible-work
  # A ticket MUST identify an acknowledged durable admission monitored for the
  # caller or its named local worker; only issuer or worker MAY complete it.
  # Unavailable measurement MUST return unrecorded and persist/report a gap;
  # it MUST NOT change application authorization or silently claim coverage.
  @spec admit(atom(), pid()) :: ticket()
  def admit(name, owner \\ self())

  def admit(name, owner) when is_pid(owner) and node(owner) == node() do
    try do
      GenServer.call(name, {:admit, owner, System.monotonic_time(:millisecond) + 4_000}, 5_000)
    catch
      :exit, _ ->
        GenServer.cast(name, :gap)
        :unrecorded
    end
  end

  def admit(_name, _owner), do: :unrecorded

  # @cc [owner:ghuntley,label:reliability;security] producer-single-authorized-completion
  # Only the issuer or admitted local worker MAY settle an outstanding ticket.
  # Repeated or foreign completions MUST NOT emit another terminal recorder RPC.
  @spec complete(atom(), ticket(), outcome(), non_neg_integer()) :: :ok
  def complete(_name, :unrecorded, _outcome, _duration_us), do: :ok

  def complete(name, ticket, outcome, duration_us)
      when is_reference(ticket) and outcome in [:success, :failure, :exclude] and
             is_integer(duration_us) and duration_us >= 0 and duration_us <= @max_counter do
    try do
      GenServer.call(name, {:complete, ticket, outcome, duration_us}, 5_000)
    catch
      :exit, _ ->
        GenServer.cast(name, :gap)
        :ok
    end
  end

  def complete(_name, _ticket, _outcome, _duration_us), do: :ok

  # @cc [owner:ghuntley,label:reliability] measured-source-terminal-once
  # Measurement MUST admit before invoking eligible work and settle one outcome
  # on return, exception, throw or exit. The work's return or failure semantics
  # MUST be preserved; forced worker death remains independently monitored.
  @spec measure(atom(), (-> result), (result -> :success | :failure | :exclude)) :: result
        when result: term()
  def measure(name, work, classify) do
    started = System.monotonic_time(:microsecond)
    ticket = admit(name)

    try do
      result = work.()
      complete(name, ticket, classify.(result), elapsed(started))
      result
    catch
      kind, value ->
        stack = __STACKTRACE__
        complete(name, ticket, :failure, elapsed(started))
        :erlang.raise(kind, value, stack)
    end
  end

  @spec elapsed(integer()) :: non_neg_integer()
  defp elapsed(started),
    do: min(@max_counter, max(0, System.monotonic_time(:microsecond) - started))
end
