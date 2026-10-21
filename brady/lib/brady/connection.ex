defmodule Brady.Connection do
  @moduledoc "Kernel-derived connection identity and explicit TLS interception/tunnel dispatch."
  alias Brady.{Destination, Log, Proxy, TLS, Transport, Tunnel, Upstream}

  # @cc [owner:ghuntley,label:security] brady-kernel-destination-and-tls-exception
  # Destination and peer addresses MUST come from the accepted transparent
  # socket, never a request header. Only an exact configured hostname/port pair
  # may tunnel. Malformed TLS, signing failure and upstream failure MUST close
  # the connection without falling back to tunnelling or direct guest egress.
  # @cc [owner:ghuntley,label:observability] brady-pre-admission-refusal
  # A disallowed kernel destination MUST emit a policy refusal without addresses
  # or guest bytes. Socket identity failures MUST emit a transport outcome.
  # Neither outcome may be counted as an admitted request in the SLO.
  @spec run(:gen_tcp.socket(), :http | :https, map()) :: :ok
  def run(socket, scheme, config) do
    try do
      with {:ok, {ip, port} = destination} <- :inet.sockname(socket),
           {:ok, peer} <- :inet.peername(socket),
           true <- Destination.allowed?(ip, port, config.destination_policy) do
        identity = attribution(config, %{source: peer, destination: destination})

        dispatch(socket, scheme, destination, config, identity)
      else
        false ->
          Log.request(%{protocol: scheme, reason: :policy, attribution: :unresolved})

        _ ->
          Log.request(%{protocol: scheme, reason: :transport, attribution: :unresolved})
      end
    rescue
      _ ->
        Log.request(%{
          event: :request,
          protocol: scheme,
          reason: :internal,
          attribution: :unresolved
        })
    catch
      :exit, _ -> Log.request(%{protocol: scheme, reason: :internal, attribution: :unresolved})
    after
      :gen_tcp.close(socket)
    end

    :ok
  end

  defp dispatch(socket, scheme, destination, config, identity) do
    if scheme == :http do
      Proxy.serve({:tcp, socket}, destination, :http, config, identity)
    else
      https(socket, destination, identity, config)
    end
  rescue
    _ -> Log.request(Map.merge(identity, %{protocol: scheme, reason: :internal}))
  catch
    :exit, _ -> Log.request(Map.merge(identity, %{protocol: scheme, reason: :internal}))
  end

  # @cc [owner:ghuntley,label:security] brady-connection-attribution-snapshot
  # Attribution MUST receive the complete kernel source and destination tuple
  # once, before reading guest bytes. All logs for that connection MUST retain
  # the captured identity; a later owner lookup MUST NOT relabel an old flow.
  # Lookup failure MUST produce unresolved attribution without direct bypass.
  defp attribution(config, flow) do
    case config.attribution.(flow) do
      identity when is_map(identity) -> identity
      _ -> %{attribution: :unresolved}
    end
  rescue
    _ -> %{attribution: :unresolved}
  catch
    :exit, _ -> %{attribution: :unresolved}
  end

  defp https(socket, {ip, port} = destination, identity, config) do
    with {:ok, sni, wire} <- TLS.Hello.read(socket),
         host = sni || ip |> :inet.ntoa() |> List.to_string(),
         true <- Destination.acceptable?(:https, host, port, destination, config.resolver) do
      cond do
        # A tunnel is never TLS-verified by Brady, so an operator exception
        # still requires the hostname to resolve to the original destination.
        MapSet.member?(config.tls_exceptions, {host, port}) and
            Destination.matches?(host, port, destination, config.resolver) ->
          tunnel(socket, destination, host, identity, wire, config)

        MapSet.member?(config.tls_exceptions, {host, port}) ->
          Log.request(
            Map.merge(identity, %{protocol: :https, port: port, reason: :tls, cache: :bypass})
          )

        true ->
          with :ok <- :gen_tcp.unrecv(socket, wire),
               {:ok, client, ^host} <- TLS.accept(socket, config.signer, host) do
            Proxy.serve(client, destination, :https, config, identity, host)
          else
            _ ->
              Log.request(
                Map.merge(identity, %{
                  protocol: :https,
                  port: port,
                  reason: :tls,
                  cache: :bypass
                })
              )
          end
      end
    else
      _ ->
        Log.request(
          Map.merge(identity, %{
            protocol: :https,
            port: port,
            reason: :tls,
            cache: :bypass
          })
        )
    end
  end

  defp tunnel(socket, destination, host, identity, wire, config) do
    started = System.monotonic_time(:microsecond)
    # Explicit splicing preserves client-authenticated TLS, including mTLS and
    # certificate pins. The proxy cannot inspect/cache this encrypted stream.
    case Upstream.connect(destination, :http, host, config) do
      {:ok, {:tcp, upstream} = transport} ->
        try do
          fields =
            case Tunnel.run(socket, upstream, wire) do
              {:ok, sent, received} -> %{bytes_received: sent, bytes_sent: received, reason: :ok}
              _ -> %{reason: :upstream}
            end

          Log.request(
            Map.merge(
              identity,
              Map.merge(
                fields,
                %{
                  protocol: :tunnel,
                  port: elem(destination, 1),
                  cache: :bypass,
                  duration_us: max(0, System.monotonic_time(:microsecond) - started)
                }
              )
            )
          )
        after
          Transport.close(transport)
        end

      _ ->
        Log.request(
          Map.merge(identity, %{
            protocol: :tunnel,
            reason: :upstream,
            cache: :bypass
          })
        )
    end
  end
end
