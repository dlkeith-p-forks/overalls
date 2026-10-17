defmodule Brady.Proxy do
  @moduledoc "One bounded HTTP/1 exchange per intercepted connection, streamed through the admitted origin."
  alias Brady.{Cache, Destination, HTTP.Head, HTTP.Stream, Log, Transport, Upstream}

  # @cc [owner:ghuntley,label:security] brady-exchange-authority-before-cache
  # Every exchange MUST validate Host before cache lookup: HTTP Host against the
  # original destination, HTTPS Host equal to the handshake SNI on the original
  # port, with the origin authenticated by upstream TLS identity (see
  # brady-https-origin-by-upstream-identity).
  # Cache miss/failure MUST use the same admitted upstream path. Failures after
  # response headers MUST close the connection, never append a second response.
  @spec serve(
          Transport.t(),
          {Destination.ipv4(), pos_integer()},
          :http | :https,
          map(),
          map(),
          String.t() | nil
        ) :: :ok
  def serve(client, destination, scheme, config, identity, tls_host \\ nil) do
    Overalls.Diagnostics.Tracing.with_span("brady.http", [], fn ->
      serve_traced(client, destination, scheme, config, identity, tls_host)
    end)
  end

  @spec serve_traced(
          Transport.t(),
          {Destination.ipv4(), pos_integer()},
          :http | :https,
          map(),
          map(),
          String.t() | nil
        ) :: :ok
  defp serve_traced(client, destination, scheme, config, identity, tls_host) do
    started = System.monotonic_time(:microsecond)
    base = Map.merge(identity, %{protocol: scheme, port: elem(destination, 1)})

    result =
      try do
        exchange(
          client,
          destination,
          scheme,
          config,
          tls_host,
          Map.get(identity, :attribution) == :resolved
        )
      rescue
        _ -> {:error, :internal}
      catch
        :exit, _ -> {:error, :internal}
      end

    event =
      case result do
        {:admitted, {:ok, fields}} -> Map.put(fields, :slo_admitted, :yes)
        {:admitted, {:error, reason}} -> %{reason: reason, cache: :failed, slo_admitted: :yes}
        {:error, reason} -> %{reason: reason, cache: :failed}
      end

    Log.request(
      Map.merge(
        base,
        Map.put(event, :duration_us, max(0, System.monotonic_time(:microsecond) - started))
      )
    )

    Transport.close(client)
    :ok
  end

  # @cc [owner:ghuntley,label:reliability;security] brady-slo-admission-boundary
  # An exchange MUST mark SLO admission only after kernel destination, parsed
  # request authority and method pass validation. Invalid requests and failures
  # before this boundary MUST NOT carry the admitted marker.
  @spec exchange(
          Transport.t(),
          {Destination.ipv4(), pos_integer()},
          :http | :https,
          map(),
          String.t() | nil,
          boolean()
        ) :: {:admitted, {:ok, map()} | {:error, atom()}} | {:error, :invalid_request}
  defp exchange(client, {ip, port} = destination, scheme, config, tls_host, eligible) do
    with true <- Destination.allowed?(ip, port, config.destination_policy),
         {:ok, head, buffer} <- Stream.head(client, :request),
         [authority] <- Cache.Policy.values(head.headers, "host"),
         {:ok, host, authority_port} <-
           Destination.authority(authority, if(scheme == :https, do: 443, else: 80)),
         true <-
           Destination.acceptable?(scheme, host, authority_port, destination, config.resolver),
         true <- scheme == :http or host == tls_host,
         true <- head.method != "CONNECT" and Cache.Policy.values(head.headers, "upgrade") == [],
         request = %{
           method: head.method,
           scheme: scheme,
           host: host,
           port: port,
           target: head.target,
           headers: head.headers
         } do
      attempt = fn ->
        # Requests with bodies never reuse a cache entry, even for GET.
        result =
          case if(head.body in [:none, {:length, 0}],
                 do: Cache.lookup(config.cache, request, System.system_time(:second)),
                 else: :miss
               ) do
            {:hit, ref, response, offset, length} ->
              try do
                with :ok <- Transport.send(client, Head.response_bytes(response)),
                     :ok <-
                       Cache.stream(
                         config.cache,
                         ref,
                         offset,
                         length,
                         &Transport.send(client, &1)
                       ) do
                  {:ok,
                   %{
                     method: head.method,
                     status: response.status,
                     cache: :hit,
                     bytes_received: 0,
                     bytes_sent: length,
                     reason: :ok
                   }}
                end
              after
                Cache.close(config.cache, ref)
              end

            :miss ->
              forward(client, destination, request, head, buffer, config)
          end

        {:admitted, result}
      end

      if eligible do
        Overalls.RequestAccounting.Producer.measure(Brady.RequestRecorder, attempt, fn
          {:admitted, {:ok, %{reason: :ok}}} ->
            :success

          {:admitted, {:error, reason}}
          when reason in [
                 :upstream,
                 :tls,
                 :timeout,
                 :capacity,
                 :storage,
                 :internal,
                 :transport,
                 :closed
               ] ->
            :failure

          _ ->
            :exclude
        end)
      else
        attempt.()
      end
    else
      _ ->
        error_response(client, 400)
        {:error, :invalid_request}
    end
  end

  defp forward(client, destination, request, head, buffer, config) do
    case Upstream.connect(destination, request.scheme, request.host, config) do
      {:ok, upstream} ->
        try do
          sent = System.system_time(:second)

          with :ok <- expect_continue(client, head),
               outgoing = %{
                 head
                 | headers: Enum.reject(head.headers, fn {key, _} -> key == "expect" end)
               },
               :ok <- Transport.send(upstream, Head.request_bytes(outgoing)),
               {:ok, _, uploaded} <-
                 Stream.body(client, head.body, buffer, &Transport.send(upstream, &1)),
               {:ok, response, rest} <- final_head(upstream, 0),
               received = System.system_time(:second) do
            response = if head.method == "HEAD", do: %{response | body: :none}, else: response

            cache_request =
              if head.body in [:none, {:length, 0}],
                do: request,
                else: %{request | headers: [{"cache-control", "no-store"} | request.headers]}

            deliver(
              client,
              upstream,
              cache_request,
              response,
              rest,
              sent,
              received,
              uploaded,
              config
            )
          end
        after
          Transport.close(upstream)
        end

      {:error, reason} ->
        error_response(client, 502)
        {:error, reason}
    end
  end

  defp deliver(client, upstream, request, response, rest, sent, received, uploaded, config) do
    write = Cache.begin_write(config.cache, request, response, sent, received)

    try do
      with :ok <- Transport.send(client, Head.response_bytes(response)),
           {:ok, _, downloaded} <-
             Stream.body(upstream, response.body, rest, &Transport.send(client, &1), fn
               {:payload, bytes} ->
                 case write do
                   {:ok, ref} -> Cache.append(config.cache, ref, bytes)
                   _ -> :ok
                 end

                 :ok

               :trailers ->
                 case write do
                   {:ok, ref} -> Cache.abort(config.cache, ref)
                   _ -> :ok
                 end

                 :ok
             end) do
        publication =
          case write do
            {:ok, ref} ->
              if Cache.commit(config.cache, ref) == :ok, do: :published, else: :abandoned

            _ ->
              :not_attempted
          end

        {:ok,
         %{
           method: request.method,
           status: response.status,
           cache: if(match?({:ok, _}, write), do: :miss, else: :bypass),
           cache_write: publication,
           bytes_received: uploaded,
           bytes_sent: downloaded,
           reason: :ok
         }}
      end
    after
      case write do
        {:ok, ref} -> Cache.abort(config.cache, ref)
        _ -> :ok
      end
    end
  end

  defp final_head(upstream, count, buffer \\ "")

  defp final_head(upstream, count, buffer) when count < 8 do
    case Stream.head(upstream, :response, buffer) do
      {:ok, %{status: status}, rest} when status in 100..199 ->
        if status == 101, do: {:error, :upstream}, else: final_head(upstream, count + 1, rest)

      result ->
        result
    end
  end

  defp final_head(_, _, _), do: {:error, :upstream}

  defp expect_continue(client, head) do
    case Cache.Policy.values(head.headers, "expect") do
      [] ->
        :ok

      [value] ->
        if String.downcase(value) == "100-continue",
          do: Transport.send(client, "HTTP/1.1 100 Continue\r\n\r\n"),
          else: {:error, :invalid_request}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp error_response(client, status),
    do:
      Transport.send(
        client,
        Head.response_bytes(%{status: status, headers: [], body: {:length, 0}})
      )
end
