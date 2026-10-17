defmodule Audi.TLS.Probe do
  @moduledoc "Verify the local listener serves the installed certificate for a specific SNI name."

  # @cc [owner:ghuntley,label:security] audi-local-tls-readiness-proof
  # Readiness checks MUST complete a verified TLS handshake on a configured
  # locally assigned IPv4 listener using the exact requested SNI and operator
  # roots. The connection MUST bind that same local address, and the served
  # leaf fingerprint MUST match installed metadata. A wildcard is acceptable
  # only when normal hostname verification matches that SNI. IPv6 and remote
  # addresses, session caches, verification bypass and hostname fallback MUST
  # NOT establish readiness.
  @spec check({:inet.ip_address(), :inet.port_number()}, map(), binary()) ::
          :ok | {:error, atom()}
  def check({ip, port}, metadata, roots)
      when port in 1..65_535 do
    with true <- local_ipv4?(ip),
         true <- is_binary(roots) and byte_size(roots) in 1..1_048_576,
         certificates =
           for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(roots), do: der),
         true <- length(certificates) in 1..256,
         true <- metadata.expires_at > System.system_time(:second),
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
               server_name_indication: String.to_charlist(metadata.hostname),
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ],
               versions: [:"tlsv1.3", :"tlsv1.2"],
               reuse_sessions: false,
               session_tickets: :disabled,
               log_level: :none
             ],
             2000
           ) do
      try do
        with true <- local_ipv4?(ip),
             {:ok, leaf} <- :ssl.peercert(socket),
             true <-
               Base.encode16(:crypto.hash(:sha256, leaf), case: :lower) == metadata.fingerprint,
             do: :ok,
             else: (_ -> {:error, :tls_not_ready})
      after
        :ssl.close(socket)
      end
    else
      _ -> {:error, :tls_not_ready}
    end
  rescue
    _ -> {:error, :tls_not_ready}
  catch
    _, _ -> {:error, :tls_not_ready}
  end

  def check(_, _, _), do: {:error, :tls_not_ready}

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
