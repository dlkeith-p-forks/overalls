defmodule Overalls.Diagnostics.Tracing do
  @moduledoc "Reviewed OpenTelemetry span production with fail-open application semantics."

  @operations ~w(
    lilly.host.utility
    lilly.transfer.stream
    enrico.git.utility
    enrico.http
    marshall.http
    audi.http
    brady.http
    galileo.http
    ziggy.http
    porsche.ssh.dispatch
    peach.http
  )

  @type metadata :: Overalls.Diagnostics.metadata()

  @doc "Runs a reviewed operation in one span while preserving the exact callback outcome."
  @spec with_span(binary(), metadata(), (-> result)) :: result when result: term()
  def with_span(name, metadata, fun) when name in @operations and is_function(fun, 0) do
    if Overalls.Diagnostics.Configuration.configured?(),
      do: observe(name, metadata, fun),
      else: fun.()
  end

  @doc false
  @spec emit_event(Overalls.Diagnostics.Events.Catalog.projection(), metadata(), (-> result)) ::
          result
        when result: term()
  def emit_event(%{event: name, trace?: true, delivery: :routine}, metadata, callback)
      when is_function(callback, 0) do
    if Overalls.Diagnostics.Configuration.configured?(),
      do: observe(name, metadata, callback),
      else: callback.()
  end

  def emit_event(_projection, _metadata, callback) when is_function(callback, 0), do: callback.()

  # @cc [owner:ghuntley,label:recovery] trace-wrapper-fail-open
  # SDK/export failure MUST preserve the application's single invocation and
  # exact result/exception. Trace attributes MUST NOT include exception text.
  @spec observe(binary(), metadata(), (-> result)) :: result when result: term()
  defp observe(name, metadata, fun) do
    key = {__MODULE__, :observation, make_ref()}
    Process.put(key, :not_started)

    try do
      :otel_tracer.with_span(
        tracer(),
        name,
        %{attributes: Overalls.Diagnostics.Context.attributes(metadata), kind: span_kind(name)},
        fn span ->
          Process.put(key, :executing)

          try do
            result = fun.()
            Process.put(key, {:returned, result})
            :ok = safe_status(span, result_status(result))
            result
          catch
            kind, reason ->
              Process.put(key, {:raised, kind, reason, __STACKTRACE__})
              :ok = safe_status(span, :error)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end
        end
      )
    catch
      kind, reason ->
        case Process.get(key) do
          :not_started -> fun.()
          {:returned, result} -> result
          {:raised, original, exception, stack} -> :erlang.raise(original, exception, stack)
          _ -> :erlang.raise(kind, reason, __STACKTRACE__)
        end
    after
      Process.delete(key)
    end
  end

  @spec result_status(term()) :: :ok | :error
  defp result_status({:error, _}), do: :error
  defp result_status(%{status: status}) when is_integer(status) and status >= 500, do: :error
  defp result_status(_), do: :ok

  @spec safe_status(:opentelemetry.span_ctx(), :ok | :error) :: :ok
  defp safe_status(span, status) do
    _ = :otel_span.set_status(span, status)
    :ok
  catch
    _, _ -> :ok
  end

  @spec tracer() :: :opentelemetry.tracer()
  defp tracer, do: :persistent_term.get({__MODULE__, :tracer}, {:otel_tracer_noop, []})

  @spec span_kind(binary()) :: :internal | :server
  defp span_kind(name) do
    if name in ~w(marshall.http audi.http brady.http galileo.http ziggy.http porsche.ssh.dispatch peach.http enrico.http),
      do: :server,
      else: :internal
  end
end
