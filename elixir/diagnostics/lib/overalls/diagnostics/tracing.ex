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
    marshall.agent.server_tool
    marshall.artifact.publish
    marshall.artifact.content
    marshall.cedar.authorize
    marshall.live.callback
    marshall.live.refresh
    marshall.views.read
  )

  @type metadata :: Overalls.Diagnostics.metadata()
  @opaque span :: {:opentelemetry.span_ctx(), :otel_ctx.token()} | :none

  @doc "Runs a reviewed operation in one span while preserving the exact callback outcome."
  @spec with_span(binary(), metadata(), (-> result)) :: result when result: term()
  def with_span(name, metadata, fun) when name in @operations and is_function(fun, 0) do
    if Overalls.Diagnostics.Configuration.configured?(),
      do: observe(name, metadata, fun),
      else: fun.()
  end

  # @cc [owner:ghuntley,label:observability;security] trace-annotate-reviewed-attributes
  # Annotation MUST add only reviewed schema attributes to the current span,
  # MUST be a no-op without a recording span or configuration, and MUST NOT
  # raise into the application or change its result.
  @doc "Adds reviewed attributes, such as counts known only at the end, to the current span."
  @spec annotate(metadata()) :: :ok
  def annotate(metadata) do
    if Overalls.Diagnostics.Configuration.configured?() do
      attributes = Overalls.Diagnostics.Context.attributes(metadata)

      if attributes != %{},
        do: _ = :otel_span.set_attributes(:otel_tracer.current_span_ctx(), attributes)
    end

    :ok
  catch
    _, _ -> :ok
  end

  # @cc [owner:ghuntley,label:observability;recovery] trace-start-finish-paired
  # A started span MUST become the current span until its finish, which MUST
  # end it, restore the previous context and set only a closed status. Both
  # MUST fail open: without configuration, or on any SDK failure, start MUST
  # return a handle whose finish is a no-op, and neither MUST raise.
  @doc """
  Starts a reviewed operation for callers that observe only begin and end
  events, such as Telemetry span handlers. Pair it with `finish/3` in the
  same process.
  """
  @spec start(binary(), metadata()) :: span()
  def start(name, metadata) when name in @operations do
    if Overalls.Diagnostics.Configuration.configured?() do
      span =
        :otel_tracer.start_span(tracer(), name, %{
          attributes: Overalls.Diagnostics.Context.attributes(metadata),
          kind: span_kind(name)
        })

      token = :otel_ctx.attach(:otel_tracer.set_current_span(:otel_ctx.get_current(), span))
      {span, token}
    else
      :none
    end
  catch
    _, _ -> :none
  end

  @doc "Ends a span from `start/2` with a closed status and reviewed end attributes."
  @spec finish(span(), :ok | :error, metadata()) :: :ok
  def finish(span, status, metadata \\ [])

  def finish({span, token}, status, metadata) when status in [:ok, :error] do
    try do
      attributes = Overalls.Diagnostics.Context.attributes(metadata)
      if attributes != %{}, do: _ = :otel_span.set_attributes(span, attributes)
      :ok = safe_status(span, status)
      _ = :otel_span.end_span(span)
    catch
      _, _ -> :ok
    after
      detach(token)
    end

    :ok
  end

  def finish(_span, _status, _metadata), do: :ok

  @spec detach(:otel_ctx.token()) :: :ok
  defp detach(token) do
    _ = :otel_ctx.detach(token)
    :ok
  catch
    _, _ -> :ok
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
    if name in ~w(marshall.http marshall.artifact.content audi.http brady.http galileo.http ziggy.http porsche.ssh.dispatch peach.http enrico.http),
      do: :server,
      else: :internal
  end
end
