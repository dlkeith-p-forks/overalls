defmodule Overalls.Diagnostics.Exporter do
  @moduledoc "Official OTLP conversion with private, bounded durable-custody handoff."
  require Record
  import Kernel, except: [send: 2]

  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  @scope_index Enum.find_index(@fields, fn {key, _} -> key == :instrumentation_scope end) + 2
  @type result :: :ok | {:error, :unavailable | :refused}

  # @cc [owner:ghuntley,label:recovery;security] exporter-durable-reply
  # Only an empty successful spool response MAY return :ok. Provider bodies,
  # transport exceptions and SDK diagnostics MUST NOT reach application logs.
  @spec export(:opentelemetry.span() | [:opentelemetry.span()]) :: result()
  def export(span) do
    case System.get_env("OVERALLS_TRACE_SOCKET") do
      nil -> {:error, :unavailable}
      socket -> send(encode(span), socket)
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  @spec encode(:opentelemetry.span() | [:opentelemetry.span()]) :: binary()
  def encode(span) do
    table = :ets.new(:overalls_otlp_export, [:bag, {:keypos, @scope_index}])

    try do
      true = :ets.insert(table, List.wrap(span))
      proto = :otel_otlp_traces.to_proto(table, :otel_resource.create([]))
      :opentelemetry_exporter_trace_service_pb.encode_msg(proto, :export_trace_service_request)
    after
      :ets.delete(table)
    end
  end

  @spec send(binary(), binary()) :: result()
  def send(body, socket) when byte_size(body) <= 262_144 do
    case Req.post(
           url: "http://localhost/v1/traces",
           unix_socket: socket,
           body: body,
           headers: [{"content-type", "application/x-protobuf"}],
           retry: false,
           redirect: false,
           decode_body: false,
           receive_timeout: 250,
           connect_options: [timeout: 250]
         ) do
      {:ok, %{status: status, body: ""}} when status in [200, 202, 204] -> :ok
      {:ok, _} -> {:error, :refused}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  def send(_body, _socket), do: {:error, :refused}
end
