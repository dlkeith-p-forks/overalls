defmodule Lilly.Lifecycle.PublicationDiagnostics do
  @moduledoc "Bounded committed diagnostics, handed off only after their native writer releases."
  require Lilly.Events
  alias Lilly.Host.Lock
  @key {__MODULE__, :pending}
  @limit 128
  @type diagnostic :: %{
          required(:event_id) => String.t(),
          required(:resource_id) => String.t(),
          required(:resource_type) => atom(),
          required(:action) => atom(),
          required(:next_state) => atom(),
          required(:revision) => pos_integer(),
          required(:occurred_at) => pos_integer(),
          optional(:previous_state) => atom(),
          optional(:host_id) => String.t(),
          optional(:pool_id) => String.t(),
          optional(:placement_id) => String.t(),
          optional(:workflow_id) => String.t()
        }
  @type pending :: %{Lilly.Host.Lease.t() => [diagnostic()]}

  # @cc [owner:ghuntley,label:observability;concurrency;recovery] lifecycle-diagnostic-bounded-defer
  # A native publication MUST perform no exporter I/O under its writer lock.
  # Keep at most 128 immutable diagnostics per caller; excess diagnostics may
  # drop without changing publication success or physical receipt authority.
  @spec defer(diagnostic()) :: :ok
  def defer(diagnostic) do
    queue = pending()

    if port = Lock.current() do
      if Enum.sum(Enum.map(queue, fn {_, values} -> length(values) end)) < @limit do
        Process.put(@key, Map.update(queue, port, [diagnostic], &[diagnostic | &1]))
      end
    end

    :ok
  end

  # @cc [owner:ghuntley,label:observability;recovery] lifecycle-handoff-after-native-release
  # The matching owner MUST confirm helper exit before any diagnostic handoff.
  # Uncertain release drops that bounded batch. SDK admission MUST not wait for
  # a spool response, and MUST NOT imply durable custody.
  @spec released(Lilly.Host.Lease.t(), :ok | {:error, :host_lock_release_unconfirmed}) :: :ok
  def released(port, result) do
    {diagnostics, remaining} = Map.pop(pending(), port, [])
    Process.put(@key, remaining)

    if result == :ok do
      diagnostics |> Enum.reverse() |> Enum.each(&emit/1)
    end

    :ok
  end

  @spec pending() :: pending()
  defp pending, do: Process.get(@key, %{})

  @spec emit(diagnostic()) :: :ok
  defp emit(diagnostic) do
    _ = Lilly.Lifecycle.Observability.enqueue_transition(diagnostic)

    Lilly.Events.emit("lilly.lifecycle_transition_committed",
      event_id: diagnostic.event_id,
      resource_type: diagnostic.resource_type,
      resource_id: diagnostic.resource_id,
      action: diagnostic.action,
      previous_state: diagnostic[:previous_state],
      next_state: diagnostic.next_state,
      occurred_at: diagnostic.occurred_at,
      revision: diagnostic.revision,
      host_id: diagnostic[:host_id],
      pool_id: diagnostic[:pool_id],
      placement_id: diagnostic[:placement_id],
      workflow_id: diagnostic[:workflow_id]
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
