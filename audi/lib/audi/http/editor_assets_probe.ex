defmodule Audi.HTTP.EditorAssetsProbe do
  @moduledoc "Verified, bounded HTTPS proof that the configured listener serves its editor assets."
  alias OverallsProtocol.EditorRelease
  @hash String.duplicate("0", 52)
  @relative "out/vs/workbench/contrib/webview/browser/pre/index.html"
  @limit 8192
  @timeout 1500

  # @cc [owner:ghuntley,label:security;recovery] audi-assets-live-listener-proof
  # A receipt MUST require a verified TLS HEAD through the configured, locally
  # assigned IPv4 HTTPS listener, using operator roots and exact canonical hash
  # SNI/Host/current-release path. The complete proof MUST have a finite deadline
  # and bounded headers. Redirects, unavailable acceptors, wrong trust and missing
  # immutable asset headers MUST NOT establish readiness. No DNS, credentials,
  # guest authority, cached handshake or diagnostic payload may enter this probe.
  @spec check({:inet.ip_address(), :inet.port_number()}, binary(), binary(), EditorRelease.t()) ::
          :ok | {:error, :editor_assets_not_ready}
  def check({ip, port}, zone, roots, descriptor) when port in 1..65_535 do
    deadline = System.monotonic_time(:millisecond) + @timeout

    with true <- local_ipv4?(ip),
         true <- OverallsProtocol.EditorConnect.zone?(zone),
         hostname = @hash <> "." <> zone,
         true <- is_binary(roots) and byte_size(roots) in 1..1_048_576,
         entries = :public_key.pem_decode(roots),
         true <- length(entries) in 1..256,
         true <- Enum.all?(entries, &match?({:Certificate, _, :not_encrypted}, &1)),
         certificates = Enum.map(entries, fn {:Certificate, der, :not_encrypted} -> der end),
         {:ok, _} <-
           EditorRelease.decode(%{
             "protocol" => descriptor.protocol,
             "commit" => descriptor.commit,
             "release" => descriptor.release
           }),
         {:ok, socket} <-
           :ssl.connect(
             ip,
             port,
             [
               :inet,
               :binary,
               ip: ip,
               active: false,
               verify: :verify_peer,
               cacerts: certificates,
               server_name_indication: String.to_charlist(hostname),
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ],
               versions: [:"tlsv1.3", :"tlsv1.2"],
               reuse_sessions: false,
               session_tickets: :disabled,
               send_timeout: @timeout,
               send_timeout_close: true,
               log_level: :none
             ],
             remaining(deadline)
           ) do
      try do
        authority = hostname <> if(port == 443, do: "", else: ":#{port}")
        path = "/code-assets/" <> descriptor.release <> "/" <> @relative

        with true <- local_ipv4?(ip) and remaining(deadline) > 0,
             :ok <- :ssl.setopts(socket, send_timeout: remaining(deadline)),
             :ok <-
               :ssl.send(socket, [
                 "HEAD ",
                 path,
                 " HTTP/1.1\r\nHost: ",
                 authority,
                 "\r\nConnection: close\r\n\r\n"
               ]),
             {:ok, headers} <- headers(socket, deadline, ""),
             true <- valid_headers?(headers),
             true <- remaining(deadline) > 0,
             do: :ok,
             else: (_ -> {:error, :editor_assets_not_ready})
      after
        :ssl.close(socket)
      end
    else
      _ -> {:error, :editor_assets_not_ready}
    end
  rescue
    _ -> {:error, :editor_assets_not_ready}
  catch
    _, _ -> {:error, :editor_assets_not_ready}
  end

  def check(_, _, _, _), do: {:error, :editor_assets_not_ready}

  @spec headers(:ssl.sslsocket(), integer(), binary()) :: {:ok, binary()} | :error
  defp headers(socket, deadline, bytes) when byte_size(bytes) <= @limit do
    case :binary.match(bytes, "\r\n\r\n") do
      {offset, 4} ->
        {:ok, binary_part(bytes, 0, offset)}

      :nomatch ->
        with timeout when timeout > 0 <- remaining(deadline),
             {:ok, more} <- :ssl.recv(socket, 0, timeout),
             do: headers(socket, deadline, bytes <> more),
             else: (_ -> :error)
    end
  end

  defp headers(_, _, _), do: :error

  @spec valid_headers?(binary()) :: boolean()
  defp valid_headers?(bytes) do
    case String.split(bytes, "\r\n") do
      ["HTTP/1.1 200 OK" | lines] when length(lines) <= 32 ->
        headers =
          Enum.map(lines, fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] -> {String.downcase(name), String.trim(value)}
              _ -> :invalid
            end
          end)

        :invalid not in headers and
          Enum.filter(headers, fn {key, _} -> key == "cache-control" end) ==
            [{"cache-control", "public, max-age=31536000, immutable"}] and
          Enum.filter(headers, fn {key, _} -> key == "content-type" end) ==
            [{"content-type", "text/html; charset=utf-8"}] and
          Enum.filter(headers, fn {key, _} -> key == "x-content-type-options" end) ==
            [{"x-content-type-options", "nosniff"}] and
          Enum.all?(headers, fn {key, _} -> key not in ["set-cookie", "location"] end)

      _ ->
        false
    end
  end

  @spec remaining(integer()) :: non_neg_integer()
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @spec local_ipv4?(term()) :: boolean()
  defp local_ipv4?({a, b, c, d} = ip)
       when a in 1..223 and b in 0..255 and c in 0..255 and d in 0..255 do
    if a == 127 do
      true
    else
      case :inet.getifaddrs() do
        {:ok, interfaces} ->
          Enum.any?(interfaces, fn {_name, properties} ->
            ip in Keyword.get_values(properties, :addr)
          end)

        _ ->
          false
      end
    end
  end

  defp local_ipv4?(_), do: false
end
