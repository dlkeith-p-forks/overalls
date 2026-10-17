defmodule MarshallWeb.ObservedRouter do
  @moduledoc "Closed request tracing around the existing authenticated router."
  @behaviour Plug

  @impl true
  @spec init(keyword()) :: keyword()
  def init(options), do: MarshallWeb.Router.init(options)

  # @cc [owner:ghuntley,label:security;observability] request-trace-no-payload-or-authority
  # Tracing MUST call the existing router exactly once and preserve its response
  # and exception. Only closed method and bounded status may become attributes;
  # paths, query parameters, headers, session data and bodies MUST stay excluded.
  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, options) do
    Overalls.Diagnostics.Tracing.with_span("marshall.http", [method: method(conn.method)], fn ->
      response = MarshallWeb.Router.call(conn, options)
      annotate_status(response.status)
      response
    end)
  end

  @spec method(String.t()) :: atom() | nil
  defp method(method) do
    %{
      "GET" => :get,
      "HEAD" => :head,
      "POST" => :post,
      "PUT" => :put,
      "DELETE" => :delete,
      "OPTIONS" => :options,
      "PATCH" => :patch,
      "CONNECT" => :connect,
      "TRACE" => :trace
    }[method]
  end

  @spec annotate_status(non_neg_integer() | nil) :: :ok
  defp annotate_status(status) when is_integer(status) and status in 100..599 do
    if Overalls.Diagnostics.Configuration.configured?() do
      span = :otel_tracer.current_span_ctx()
      _ = :otel_span.set_attribute(span, "status", status)
      if status >= 500, do: :otel_span.set_status(span, :error)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp annotate_status(_), do: :ok
end
