defmodule Lilly.Lifecycle.Observability do
  @moduledoc "Typed diagnostics custody for committed lifecycle transitions."

  @event "lilly.lifecycle_transition_committed"
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

  # @cc [owner:ghuntley,label:capacity;recovery] lifecycle-diagnostic-queue-boundary
  # Queue admission MUST remain bounded and volatile. Its success result MUST
  # never be presented as durable custody or affect lifecycle publication.
  @doc "Admit a transition to the volatile bounded queue; :ok does not confirm durable custody."
  @spec enqueue_transition(diagnostic()) :: Overalls.Diagnostics.custody()
  def enqueue_transition(diagnostic), do: deliver(diagnostic)

  # @cc [owner:ghuntley,label:recovery;security] lifecycle-diagnostic-catalog-boundary
  # Dynamic lifecycle diagnostics MUST validate against Lilly.Events before
  # entering shared custody. Invalid or incomplete metadata MUST be refused
  # without exporter I/O, and no generic event name may be supplied by callers.
  @spec deliver(diagnostic()) :: Overalls.Diagnostics.custody()
  defp deliver(diagnostic) when is_map(diagnostic) do
    with {:ok, metadata} <-
           Overalls.Diagnostics.Events.Catalog.validate(Lilly.Events, @event, diagnostic),
         true <- metadata.revision > 0 and metadata.occurred_at > 0 do
      Overalls.Diagnostics.Custody.enqueue(Lilly.Events, @event, metadata)
    else
      {:error, :invalid} -> {:error, :invalid}
      false -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  catch
    _, _ -> {:error, :invalid}
  end

  defp deliver(_diagnostic), do: {:error, :invalid}
end
