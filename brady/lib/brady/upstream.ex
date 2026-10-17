defmodule Brady.Upstream do
  @moduledoc "Pinned-original-address upstream connections with independent TLS authentication."
  alias Brady.{Destination, Transport}

  # @cc [owner:ghuntley,label:security] brady-upstream-verified-origin
  # Every upstream connect MUST recheck the original IPv4 destination against
  # the protected-range policy. TLS MUST verify the origin certificate chain and
  # hostname using upstream trust, never the interception CA as implicit trust.
  # DNS answers MUST NOT replace the previously admitted destination address.
  @spec connect({Destination.ipv4(), pos_integer()}, :http | :https, String.t(), map()) ::
          {:ok, Transport.t()} | {:error, :upstream | :tls | :policy}
  def connect({ip, port}, scheme, host, config) do
    if Destination.allowed?(ip, port, config.destination_policy) do
      options =
        [
          :binary,
          active: false,
          packet: 0,
          nodelay: true,
          send_timeout: 15_000,
          send_timeout_close: true,
          buffer: 65_536
        ] ++ config.socket_options

      case :gen_tcp.connect(ip, port, options, 5_000) do
        {:ok, socket} -> upgrade(socket, scheme, host, config)
        _ -> {:error, :upstream}
      end
    else
      {:error, :policy}
    end
  end

  defp upgrade(socket, :http, _, _), do: {:ok, {:tcp, socket}}

  defp upgrade(socket, :https, host, config) do
    options = [
      verify: :verify_peer,
      cacertfile: String.to_charlist(config.upstream_ca_file),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      alpn_advertised_protocols: ["http/1.1"],
      versions: [:"tlsv1.3", :"tlsv1.2"],
      active: false,
      mode: :binary,
      log_level: :none
    ]

    case :ssl.connect(socket, options, 5_000) do
      {:ok, tls} ->
        {:ok, {:tls, tls}}

      _ ->
        :gen_tcp.close(socket)
        {:error, :tls}
    end
  end
end
