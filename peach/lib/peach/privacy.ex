defmodule Peach.Privacy do
  @moduledoc "Conservative source-level diagnostic redaction for the reflection service."

  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(:peach_privacy, {&__MODULE__.filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, :peach_privacy}} -> :ok
    end
  end

  # @cc [owner:ghuntley,label:security] peach-logger-content-exclusion
  # Raw diagnostics, process state, metadata and formatter callbacks MUST NOT
  # reach handlers. Only catalogued messages and validated metadata survive;
  # projection contents and credentials never do.
  @spec filter(map(), term()) :: map()
  def filter(event, _) do
    metadata = Map.get(event, :meta, %{})

    safe =
      Map.take(metadata, [:time, :pid, :gl])
      |> Map.merge(Overalls.Diagnostics.Context.log_context(metadata))

    name = Map.get(metadata, :event)

    {message, selected} =
      case Map.get(Peach.Events.__catalog__(), name) do
        nil ->
          {"Peach runtime diagnostic (payload redacted)", %{}}

        spec ->
          {spec.message,
           Overalls.Diagnostics.Events.Catalog.safe_metadata(spec.metadata, metadata)
           |> Map.put(:event, name)}
      end

    %{event | msg: {:string, message}, meta: Map.merge(safe, selected)}
  end
end
