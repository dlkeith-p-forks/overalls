defmodule Overalls.BradyHealthFixture do
  @moduledoc "Generate closed health input through the packaged Brady catalog and formatter."

  # @cc [owner:ghuntley,label:verification] brady-health-packaged-shape
  # The fixture MUST use the actual reviewed health declaration and formatter,
  # preserve all four declared numeric fields and discard undeclared metadata.
  @spec main() :: :ok
  def main do
    name = "brady.observability_health"
    %{message: message, metadata: declared} = Map.fetch!(Brady.Events.__catalog__(), name)

    values = %{
      trace_available: 1,
      trace_pending: 17,
      trace_queue_dropped: 23,
      trace_export_failed: 29
    }

    true = MapSet.new(Keyword.keys(declared)) == MapSet.new(Map.keys(values))

    true =
      Enum.all?(declared, fn {key, type} ->
        Overalls.Diagnostics.Events.Catalog.shape?(type, Map.fetch!(values, key))
      end)

    metadata = Map.merge(values, %{event: name, provider_body: "private-fixture"})
    event = %{msg: {:string, message}, meta: metadata}
    IO.binwrite(Brady.Log.format(event, %{}))
  end
end

Overalls.BradyHealthFixture.main()
