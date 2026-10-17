defmodule Overalls.Diagnostics.Custody do
  @moduledoc false

  @type result :: Overalls.Diagnostics.custody()
  @keys [{__MODULE__, :identity}, {__MODULE__, :mode}, {__MODULE__, :result}]

  # @cc [owner:ghuntley,label:capacity;recovery] custody-volatile-admission-boundary
  # enqueue/3 MUST strictly validate the catalog entry before queue admission.
  # Its :ok result MUST acknowledge only bounded volatile admission, never
  # independent spool custody or application-state publication.
  @doc false
  @spec enqueue(module(), binary(), Overalls.Diagnostics.metadata()) :: result()
  def enqueue(catalog, name, metadata), do: deliver(catalog, name, metadata)

  # @cc [owner:ghuntley,label:recovery;security] custody-reviewed-durable-boundary
  # Only strictly validated custody catalog entries MAY reach exporter I/O;
  # span identity and timestamp MUST come from the supplied metadata.
  @spec deliver(module(), binary(), Overalls.Diagnostics.metadata()) :: result()
  defp deliver(catalog, name, metadata) do
    with {:ok, values} <- Overalls.Diagnostics.Events.Catalog.validate(catalog, name, metadata),
         %{delivery: :custody, trace?: true} <-
           Overalls.Diagnostics.Events.Catalog.projection(catalog, name),
         occurred_at when is_integer(occurred_at) and occurred_at > 0 <- values[:occurred_at] do
      if Overalls.Diagnostics.Configuration.configured?(),
        do: record(name, values),
        else: {:error, :unavailable}
    else
      {:error, :invalid} -> {:error, :invalid}
      %{delivery: :routine} -> {:error, :refused}
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  @spec record(binary(), map()) :: result()
  defp record(name, metadata) do
    saved = Map.new(@keys, &{&1, Process.get(&1)})

    try do
      Process.put({__MODULE__, :identity}, Map.fetch!(metadata, :event_id))
      Process.put({__MODULE__, :mode}, :enqueue)
      Process.put({__MODULE__, :result}, {:error, :unavailable})

      timestamp =
        System.convert_time_unit(Map.fetch!(metadata, :occurred_at), :microsecond, :native) -
          System.time_offset()

      tracer =
        :persistent_term.get({Overalls.Diagnostics.Tracing, :tracer}, {:otel_tracer_noop, []})

      span =
        :otel_tracer.start_span(:otel_ctx.new(), tracer, name, %{
          attributes: Overalls.Diagnostics.Context.attributes(metadata),
          start_time: timestamp,
          kind: :internal
        })

      _ = :otel_span.end_span(span, timestamp)
      Process.get({__MODULE__, :result}, {:error, :unavailable})
    after
      Enum.each(saved, fn {key, value} ->
        if is_nil(value), do: Process.delete(key), else: Process.put(key, value)
      end)
    end
  end
end
