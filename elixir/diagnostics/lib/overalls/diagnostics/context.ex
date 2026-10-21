defmodule Overalls.Diagnostics.Context do
  @moduledoc "Reviewed trace and log correlation helpers."

  @uuid_keys Overalls.Diagnostics.Schema.attributes(:uuid)
  @enum_keys Overalls.Diagnostics.Schema.attributes(:enum)
  @number_keys Overalls.Diagnostics.Schema.attributes(:number)

  # @cc [owner:ghuntley,label:observability;security] trace-task-context-only
  # Deferred work MUST inherit only the current SDK span, never baggage or
  # arbitrary process/logger metadata. Invocation MUST restore the worker's
  # prior context and preserve its callback's single execution and exact outcome.
  @doc "Bind a deferred callback to the current local span without copying baggage."
  @spec wrap((-> result)) :: (-> result) when result: term()
  def wrap(callback) when is_function(callback, 0) do
    context = span_context()

    fn ->
      case attach(context) do
        {:ok, token} ->
          try do
            callback.()
          after
            detach(token)
          end

        :unavailable ->
          callback.()
      end
    end
  end

  @spec span_context() :: :otel_ctx.t()
  defp span_context do
    :otel_tracer.set_current_span(:otel_ctx.new(), :otel_tracer.current_span_ctx())
  catch
    _, _ -> %{}
  end

  @spec attach(:otel_ctx.t()) :: {:ok, :otel_ctx.token()} | :unavailable
  defp attach(context) do
    {:ok, :otel_ctx.attach(context)}
  catch
    _, _ -> :unavailable
  end

  @spec detach(:otel_ctx.token()) :: :ok
  defp detach(token) do
    _ = :otel_ctx.detach(token)
    :ok
  catch
    _, _ -> :ok
  end

  @doc false
  @spec event_log_context(Overalls.Diagnostics.Events.Catalog.projection(), keyword()) ::
          %{optional(:trace_id | :span_id) => binary()}
  def event_log_context(%{delivery: :custody}, metadata) do
    case Keyword.get(metadata, :event_id) do
      id when is_binary(id) ->
        if Overalls.Diagnostics.Schema.uuid?(id) do
          trace = Overalls.Diagnostics.IdGenerator.from_identity(id, 128)
          span = Overalls.Diagnostics.IdGenerator.from_identity(id, 64)

          %{
            trace_id: Base.encode16(<<trace::128>>, case: :lower),
            span_id: Base.encode16(<<span::64>>, case: :lower)
          }
        else
          %{}
        end

      _ ->
        %{}
    end
  end

  def event_log_context(_projection, _metadata), do: log_context(:logger.get_process_metadata())

  @doc false
  @spec attributes(Overalls.Diagnostics.metadata()) :: %{binary() => binary() | non_neg_integer()}
  def attributes(metadata) do
    metadata
    |> Map.new()
    |> Enum.reduce(%{}, fn {key, value}, result ->
      name = if is_atom(key), do: Atom.to_string(key), else: nil

      cond do
        name in @uuid_keys and Overalls.Diagnostics.Schema.uuid?(value) ->
          Map.put(result, name, value)

        name in @enum_keys and is_atom(value) and value != nil and
            Overalls.Diagnostics.Schema.enum?(value) ->
          Map.put(result, name, Atom.to_string(value))

        name in @number_keys and is_integer(value) and value >= 0 and
            value <= 9_223_372_036_854_775_807 ->
          Map.put(result, name, value)

        true ->
          result
      end
    end)
  end

  @doc "Returns valid OpenTelemetry correlation fields from logger metadata."
  @spec log_context(map() | :undefined) :: %{optional(:trace_id | :span_id) => binary()}
  def log_context(metadata) when is_map(metadata) do
    Enum.reduce(
      [{:otel_trace_id, :trace_id, 32}, {:otel_span_id, :span_id, 16}],
      %{},
      fn {source, target, size}, result ->
        case Map.get(metadata, source, Map.get(metadata, target)) do
          value when is_binary(value) and byte_size(value) == size ->
            if String.match?(value, ~r/\A[0-9a-fA-F]+\z/) and
                 value != String.duplicate("0", size),
               do: Map.put(result, target, String.downcase(value)),
               else: result

          _ ->
            result
        end
      end
    )
  end

  def log_context(_), do: %{}
end
