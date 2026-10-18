defmodule Audi.Private.Front do
  @moduledoc "Namespace-only TLS frontend; guest identity headers are always replaced."
  @behaviour Plug
  import Plug.Conn
  require Audi.Events

  @chunk_size 65_536
  @timeout 10_000
  @otel_max_bytes 1_048_576

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  # @cc [owner:ghuntley,label:security] private-front-transport-identity
  # Host and TLS SNI MUST equal a named internal service or be exactly one label before
  # the fixed integration zone. VM binding MUST come from the actual pre-NAT
  # peer via Lilly; no guest header, cookie or request body may supply it.
  # Forwarding MUST use only the private service sockets and native content
  # headers. Ordinary HTTP methods and the exact query string are preserved;
  # CONNECT and TRACE remain unavailable at this HTTP proxy boundary.
  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    Overalls.Diagnostics.Tracing.with_span("audi.http", [], fn -> call_traced(conn, opts) end)
  end

  @spec call_traced(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  defp call_traced(conn, opts) do
    :logger.update_process_metadata(%{audi_private: true})

    with :https <- conn.scheme,
         [host] <- get_req_header(conn, "host"),
         {:ok, service} <- service(host, opts),
         true <- service_allowed?(service, conn.remote_ip),
         true <- allowed_request?(service, conn),
         true <- sni_matches?(conn, host),
         true <- conn.method not in ["CONNECT", "TRACE"],
         true <- String.starts_with?(conn.request_path, "/"),
         purpose = lookup_purpose(conn),
         {:ok, binding, subscription} <-
           Audi.Private.Connector.subscribe(
             opts[:connector],
             opts[:connector_uid],
             conn.remote_ip,
             purpose
           ),
         :ok <- host_binding(binding, opts[:host_id], subscription) do
      guard = Audi.Private.Guard.start(subscription, binding)

      try do
        forward_counted(conn, opts, service, host, binding)
      after
        Audi.Private.Guard.stop(guard)
      end
    else
      _ -> send_resp(conn, 403, "Unavailable\n")
    end
  end

  defp forward_counted(conn, opts, :otel, host, binding),
    do: forward(conn, opts, :otel, host, binding)

  defp forward_counted(conn, opts, service, host, binding) do
    started = System.monotonic_time(:microsecond)
    ticket = Overalls.RequestAccounting.Producer.admit(Audi.RequestRecorder)

    try do
      result = forward(conn, opts, service, host, binding)

      Overalls.RequestAccounting.Producer.complete(
        Audi.RequestRecorder,
        ticket,
        if(is_integer(result.status) and result.status in 200..499, do: :success, else: :failure),
        max(0, System.monotonic_time(:microsecond) - started)
      )

      Audi.SLO.record(result.status, max(0, System.monotonic_time(:microsecond) - started))
      result
    catch
      kind, reason ->
        Overalls.RequestAccounting.Producer.complete(
          Audi.RequestRecorder,
          ticket,
          :failure,
          max(0, System.monotonic_time(:microsecond) - started)
        )

        Audi.SLO.record(nil, max(0, System.monotonic_time(:microsecond) - started))
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # @cc [owner:ghuntley,label:security] roster-bootstrap-route-only
  # Only the exact roster GET or host-certificate POST on the reserved SSH host may use
  # bootstrap identity. Headers and bodies MUST NOT select or broaden it.
  @doc false
  @spec lookup_purpose(Plug.Conn.t()) :: Audi.Private.Connector.purpose()
  def lookup_purpose(%{
        host: "ssh.integration.internal",
        method: "GET",
        request_path: "/ssh/v1/roster",
        query_string: ""
      }),
      do: :ssh_roster

  def lookup_purpose(%{
        host: "ssh.integration.internal",
        method: "POST",
        request_path: "/ssh/v1/host-certificate",
        query_string: ""
      }),
      do: :ssh_host_certificate

  def lookup_purpose(_), do: :services

  defp host_binding(binding, host_id, subscription) do
    if binding["host_id"] == host_id do
      :ok
    else
      :gen_tcp.close(subscription)

      Audi.Events.emit("audi.private_request_denied",
        host_id: host_id,
        reason: :binding_mismatch
      )

      {:error, :binding_mismatch}
    end
  end

  defp service("llm.internal", _opts), do: {:ok, :ziggy}
  defp service("reflection.internal", _opts), do: {:ok, :peach}
  defp service("ssh.integration.internal", _opts), do: {:ok, :ssh}

  defp service("otel.integration.internal", opts) do
    if is_binary(opts[:otel_socket]), do: {:ok, :otel}, else: {:error, :unavailable}
  end

  defp service(host, opts) do
    with {:ok, label} <- OverallsProtocol.Integration.label(host),
         true <- is_binary(opts[:galileo_socket]),
         do: {:ok, {:galileo, label}}
  end

  # 10.10/16 is the customer profile. It has no inference or integration access.
  defp service_allowed?(:ssh, _peer), do: true
  defp service_allowed?(_, _), do: true

  # @cc [owner:ghuntley,label:security] guest-otel-exact-surface
  # Guest telemetry MUST use only OTLP/HTTP protobuf metrics or traces on the
  # exact paths below. Content encoding and query strings are unavailable.
  @spec allowed_request?(atom() | tuple(), Plug.Conn.t()) :: boolean()
  def allowed_request?(:otel, conn) do
    conn.method == "POST" and conn.query_string == "" and
      conn.request_path in ["/v1/metrics", "/v1/traces"] and
      get_req_header(conn, "content-type") == ["application/x-protobuf"] and
      get_req_header(conn, "content-encoding") == [] and
      case get_req_header(conn, "content-length") do
        [] ->
          true

        [value] ->
          case Integer.parse(value) do
            {length, ""} -> length in 0..@otel_max_bytes and Integer.to_string(length) == value
            _ -> false
          end

        _ ->
          false
      end
  end

  def allowed_request?(_, _), do: true

  defp sni_matches?(conn, host) do
    case Keyword.get(get_ssl_data(conn), :sni_hostname) do
      sni when is_list(sni) -> List.to_string(sni) == host
      _ -> false
    end
  end

  defp forward(conn, opts, service, canonical, binding) do
    {socket_path, allowed} =
      case service do
        {:galileo, _label} -> {opts[:galileo_socket], ~w(content-type accept)}
        :ziggy -> {opts[:ziggy_socket], ~w(content-type accept anthropic-version anthropic-beta)}
        :peach -> {opts[:peach_socket], ~w(content-type accept)}
        :ssh -> {opts[:ziggy_socket], ~w(content-type accept)}
        :otel -> {opts[:otel_socket], ~w(content-type)}
      end

    headers = Enum.filter(conn.req_headers, fn {name, _} -> name in allowed end)
    encoded = binding |> JSON.encode!() |> Base.url_encode64(padding: false)

    # @cc [owner:ghuntley,label:security] private-upstream-canonical-host
    # Unix-socket forwarding MUST set the fixed upstream Host explicitly.
    # Guest-provided Host and identity headers MUST NOT enter this header list.
    headers = [{"host", canonical}, {"x-overalls-binding", encoded} | headers]

    with {:ok, socket} <-
           :gen_tcp.connect({:local, String.to_charlist(socket_path)}, 0, [
             :binary,
             active: false,
             packet: :raw,
             send_timeout: @timeout,
             send_timeout_close: true
           ]) do
      try do
        with {:ok, upstream} <-
               Mint.HTTP1.initiate(:http, socket, canonical, 80,
                 mode: :passive,
                 max_header_list_size: 65_536,
                 log: false
               ),
             path =
               conn.request_path <>
                 if(conn.query_string == "", do: "", else: "?" <> conn.query_string),
             {:ok, upstream, ref} <-
               Mint.HTTP1.request(
                 upstream,
                 conn.method,
                 path,
                 headers ++ [{"connection", "close"}],
                 :stream
               ),
             {:ok, conn, upstream} <-
               upload(
                 conn,
                 upstream,
                 ref,
                 if(service == :otel, do: @otel_max_bytes, else: :unlimited)
               ) do
          download(conn, upstream, ref, nil, false)
        else
          _ -> fail(conn)
        end
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> fail(conn)
    end
  end

  # @cc [owner:ghuntley,label:security] private-upload-backpressure
  # Audi MUST pull at most one fixed-size guest chunk before synchronously sending
  # it to the private service. Source failure MUST close the destination without
  # sending request EOF, and the binding guard MUST cover the complete exchange.
  defp upload(conn, upstream, ref, remaining) do
    case read_body(conn, length: @chunk_size, read_length: @chunk_size, read_timeout: @timeout) do
      {:more, bytes, conn} ->
        with {:ok, next} <- remaining_after(remaining, byte_size(bytes)),
             {:ok, upstream} <- Mint.HTTP1.stream_request_body(upstream, ref, bytes),
             do: upload(conn, upstream, ref, next)

      {:ok, bytes, conn} ->
        with {:ok, _next} <- remaining_after(remaining, byte_size(bytes)),
             {:ok, upstream} <- Mint.HTTP1.stream_request_body(upstream, ref, bytes),
             {:ok, upstream} <- Mint.HTTP1.stream_request_body(upstream, ref, :eof),
             do: {:ok, conn, upstream}

      _ ->
        {:error, :invalid_body}
    end
  end

  @spec remaining_after(:unlimited | non_neg_integer(), non_neg_integer()) ::
          {:ok, :unlimited | non_neg_integer()} | {:error, :body_too_large}
  defp remaining_after(:unlimited, _size), do: {:ok, :unlimited}
  defp remaining_after(remaining, size) when size <= remaining, do: {:ok, remaining - size}
  defp remaining_after(_, _), do: {:error, :body_too_large}

  defp download(conn, upstream, ref, status, sent) do
    case Mint.HTTP1.recv(upstream, 0, 30_000) do
      {:ok, upstream, events} ->
        case events(events, conn, ref, status, sent) do
          {:more, conn, status, sent} -> download(conn, upstream, ref, status, sent)
          {:done, conn} -> conn
          {:error, conn} -> fail(conn)
        end

      _ ->
        fail(conn)
    end
  end

  defp events([], conn, _ref, status, sent), do: {:more, conn, status, sent}

  defp events([{:status, ref, status} | rest], conn, ref, _status, false)
       when status in 100..599 and status != 101,
       do: events(rest, conn, ref, status, false)

  defp events([{:headers, ref, _headers} | rest], conn, ref, status, false)
       when status in 100..199,
       do: events(rest, conn, ref, nil, false)

  defp events([{:headers, ref, headers} | rest], conn, ref, status, false)
       when status in 200..599 do
    safe =
      Enum.filter(headers, fn {name, _} ->
        name in ~w(content-type request-id x-request-id x-ziggy-request-id retry-after)
      end)

    conn = Enum.reduce(safe, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)
    events(rest, send_chunked(conn, status), ref, status, true)
  end

  defp events([{:headers, ref, _trailers} | rest], conn, ref, status, true),
    do: events(rest, conn, ref, status, true)

  defp events([{:data, ref, data} | rest], conn, ref, status, true) do
    case chunk(conn, data) do
      {:ok, conn} -> events(rest, conn, ref, status, true)
      {:error, _} -> {:error, conn}
    end
  end

  defp events([{:done, ref}], conn, ref, _status, true), do: {:done, conn}
  defp events(_, conn, _ref, _status, _sent), do: {:error, conn}

  defp fail(%{state: state}) when state in [:sent, :chunked, :upgraded], do: exit(:shutdown)
  defp fail(conn), do: send_resp(conn, 502, "Unavailable\n")
end
