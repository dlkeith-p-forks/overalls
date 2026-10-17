defmodule OverallsProtocol.Integration do
  @moduledoc "Closed wire contracts for named edge integrations (Galileo)."
  alias OverallsProtocol.{IngressName, PrivateServices}
  @name_regex ~r/\A[a-z][a-z0-9-]{0,38}[a-z0-9]\z|\A[a-z]\z/
  @header_name_regex ~r/\A[A-Za-z0-9!#$%&'*+.^_`|~-]{1,64}\z/
  @host_regex ~r/\A[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\z/
  @strip_regex ~r/\A\/[A-Za-z0-9\-._~]+(\/[A-Za-z0-9\-._~]+)*\/?\z/
  @denied_headers ~w(host connection content-length transfer-encoding upgrade te trailer keep-alive proxy-connection proxy-authorization x-overalls-binding x-overalls-source-vm x-forwarded-for x-forwarded-host x-forwarded-proto)

  # @cc [owner:ghuntley,label:security] integration-name-closed-charset
  # Integration names MUST be lowercase DNS labels (1..40) from a closed
  # charset, excluding the reserved SSH authority label. Peer-supplied names
  # MUST never select origins or hosts directly; they only address a persisted
  # integration configuration.
  @spec name?(term()) :: boolean()
  def name?(value) when is_binary(value),
    do: value != "ssh" and byte_size(value) in 1..40 and Regex.match?(@name_regex, value)

  def name?(_), do: false

  @spec hostname(binary()) :: {:ok, binary()} | {:error, :invalid_name}
  def hostname(name) do
    if name?(name),
      do: {:ok, name <> "." <> PrivateServices.integration_zone()},
      else: {:error, :invalid_name}
  end

  # @cc [owner:ghuntley,label:security] integration-hostname-single-label
  # Only exactly one label before the fixed zone suffix addresses an
  # integration. Multi-label, trailing-dot, uppercase and off-zone hostnames
  # MUST be rejected so no peer name can escape the closed namespace.
  @spec label(term()) :: {:ok, binary()} | {:error, :invalid_hostname}
  def label(value) when is_binary(value) do
    zone = "." <> PrivateServices.integration_zone()

    with [label, ""] <- String.split(value, zone, parts: 2),
         true <- name?(label) do
      {:ok, label}
    else
      _ -> {:error, :invalid_hostname}
    end
  end

  def label(_), do: {:error, :invalid_hostname}

  # @cc [owner:ghuntley,label:security] integration-target-https-origin
  # Targets MUST be fixed HTTPS origins without userinfo, path, query or
  # fragment. Cleartext HTTP targets are rejected so injected credentials
  # never cross an unencrypted hop. Guest input never composes the target.
  @spec target(term()) :: {:ok, binary()} | {:error, :invalid_target}
  def target(value) when is_binary(value) and byte_size(value) in 8..2048 do
    with {:ok, uri} <- URI.new(value),
         %URI{
           scheme: "https",
           host: host,
           port: port,
           path: path,
           query: nil,
           userinfo: nil,
           fragment: nil
         } <-
           uri,
         true <- is_nil(path) or path == "",
         true <- (is_nil(port) and true) or port in 1..65_535,
         true <- is_binary(host) and byte_size(host) in 1..253,
         true <- Regex.match?(@host_regex, host) do
      {:ok, value}
    else
      _ -> {:error, :invalid_target}
    end
  end

  def target(_), do: {:error, :invalid_target}

  # @cc [owner:ghuntley,label:security] integration-strip-prefix-segment-aligned
  # Strip prefixes MUST be absolute paths over the URL-safe segment charset,
  # without empty segments, regex or control characters. Removal is applied
  # segment-aligned in the request direction only.
  @spec strip_prefix(term()) :: {:ok, binary()} | {:error, :invalid_strip_prefix}
  def strip_prefix(value) when is_binary(value) and byte_size(value) in 2..256 do
    if Regex.match?(@strip_regex, value) and not String.contains?(value, "//"),
      do: {:ok, value},
      else: {:error, :invalid_strip_prefix}
  end

  def strip_prefix(nil), do: {:ok, nil}
  def strip_prefix(_), do: {:error, :invalid_strip_prefix}

  # @cc [owner:ghuntley,label:security] integration-header-injection-bounded
  # Injected header names MUST be RFC 7230 tokens that cannot impersonate
  # transport, forwarding or platform identity headers. Values MUST be
  # bounded printable bytes without CR/LF/NUL so no injected value can
  # smuggle additional headers or lines. User-configured static headers
  # MUST additionally never name authorization; only the platform-computed
  # bearer/basic credentials may produce that header.
  @spec header(term()) :: {:ok, {binary(), binary()}} | {:error, :invalid_header}
  def header([name, value]) when is_binary(name) and is_binary(value) do
    if Regex.match?(@header_name_regex, name) and
         String.downcase(name) not in @denied_headers and
         byte_size(value) in 1..4096 and
         not String.contains?(value, ["\r", "\n", "\0"]),
       do: {:ok, {name, value}},
       else: {:error, :invalid_header}
  end

  def header(_), do: {:error, :invalid_header}

  @spec static_header(term()) :: {:ok, {binary(), binary()}} | {:error, :invalid_header}
  def static_header([name, value]) do
    with {:ok, {name, _}} <- header([name, value]),
         true <- String.downcase(name) != "authorization",
         do: {:ok, {name, value}},
         else: (_ -> {:error, :invalid_header})
  end

  def static_header(_), do: {:error, :invalid_header}

  # @cc [owner:ghuntley,label:security] integration-credential-values
  # Bearer and basic credentials MUST be validated as the exact Authorization
  # header value they will produce. The Porsche stdin marker is transport-only
  # and MUST never be accepted as persisted credential material.
  @spec bearer_credential(term()) :: {:ok, binary()} | {:error, :invalid_credential}
  def bearer_credential(value)
      when is_binary(value) and value != "-" and byte_size(value) in 1..4089 do
    case header(["authorization", "Bearer " <> value]) do
      {:ok, _} -> {:ok, value}
      _ -> {:error, :invalid_credential}
    end
  end

  def bearer_credential(_), do: {:error, :invalid_credential}

  @spec basic_credential(term()) :: {:ok, binary()} | {:error, :invalid_credential}
  def basic_credential(value)
      when is_binary(value) and value != "-" and byte_size(value) in 1..4096 do
    with [username, _password] <- String.split(value, ":", parts: 2),
         true <- username != "",
         true <- String.valid?(value) and not String.contains?(value, ["\r", "\n", "\0"]),
         encoded = "Basic " <> Base.encode64(value),
         {:ok, _} <- header(["authorization", encoded]) do
      {:ok, value}
    else
      _ -> {:error, :invalid_credential}
    end
  end

  def basic_credential(_), do: {:error, :invalid_credential}

  # @cc [owner:ghuntley,label:security] integration-authorization-response-closed
  # Galileo MUST only accept an authorization response with exactly a fixed
  # HTTPS target, an optional validated strip prefix, at most sixteen
  # validated injected headers, and for peers a bounded HTTPS endpoint plus
  # a purpose-built token. The bounded relative TTL requires Galileo to renew
  # execution authority while the upstream attempt remains open. Extra fields
  # never become authority.
  @spec authorization(term()) ::
          {:ok,
           %{
             target: binary(),
             strip_prefix: binary() | nil,
             headers: [{binary(), binary()}],
             peer: map() | nil,
             ttl: 500..5000
           }}
          | {:error, :invalid_authorization}
  def authorization(value) when is_map(value) do
    with true <-
           Enum.sort(Map.keys(value) -- ["peer"]) ==
             Enum.sort(~w(target strip_prefix headers ttl)),
         {:ok, target} <- target(value["target"]),
         {:ok, prefix} <- strip_prefix(value["strip_prefix"]),
         true <- is_list(value["headers"]) and length(value["headers"]) in 0..16,
         {:ok, headers} <- headers(value["headers"]),
         {:ok, peer} <- peer(value["peer"]),
         ttl when is_integer(ttl) and ttl in 500..5000 <- value["ttl"] do
      {:ok, %{target: target, strip_prefix: prefix, headers: headers, peer: peer, ttl: ttl}}
    else
      _ -> {:error, :invalid_authorization}
    end
  end

  def authorization(_), do: {:error, :invalid_authorization}

  # @cc [owner:ghuntley,label:security] integration-renewal-response-closed
  # Renewal responses MUST carry only a version and bounded relative TTL. They
  # never repeat target configuration, injected credentials or peer tokens.
  @spec renewal(term()) :: {:ok, %{ttl: 500..5000}} | {:error, :invalid_renewal}
  def renewal(%{"version" => 1, "ttl" => ttl} = value)
      when map_size(value) == 2 and is_integer(ttl) and ttl in 500..5000,
      do: {:ok, %{ttl: ttl}}

  def renewal(_), do: {:error, :invalid_renewal}

  # @cc [owner:ghuntley,label:security] integration-peer-attestation-purpose-bound
  # A peer attestation MUST carry exactly the source VM, the integration
  # name, a bounded future expiry and the fleet purpose marker. It binds no
  # other authority and never names a target beyond the verified endpoint.
  @spec peer_attestation(term()) ::
          {:ok, %{source_vm_id: binary(), name: binary(), expires_at: pos_integer()}}
          | {:error, :invalid_attestation}
  def peer_attestation(value) when is_map(value) and map_size(value) == 4 do
    with true <- value["purpose"] == "galileo-peer",
         true <- OverallsProtocol.uuid?(value["source_vm_id"]),
         true <- name?(value["name"]),
         expires = value["expires_at"],
         true <- is_integer(expires) and expires in 1..9_223_372_036_854_775_807 do
      {:ok, %{source_vm_id: value["source_vm_id"], name: value["name"], expires_at: expires}}
    else
      _ -> {:error, :invalid_attestation}
    end
  end

  def peer_attestation(_), do: {:error, :invalid_attestation}

  # @cc [owner:ghuntley,label:security] integration-peer-open-closed
  # Peer-open requests and responses MUST use exact version-one envelopes.
  # Tokens are opaque provenance values and MUST be accompanied by the canonical
  # destination label; the response requires both an attestation and an
  # independently validated web grant for that label.
  @spec peer_open_request(term()) ::
          {:ok, %{peer_token: binary(), label: binary(), app_port: 0}}
          | {:error, :invalid_peer_open}
  def peer_open_request(
        %{"version" => 1, "peer_token" => token, "label" => label, "app_port" => 0} = value
      )
      when map_size(value) == 4 and is_binary(token) and byte_size(token) == 56 do
    with true <- IngressName.valid_label?(label),
         "galileo_peer_" <> encoded when byte_size(encoded) == 43 <- token,
         {:ok, bytes} when byte_size(bytes) == 32 <- Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == encoded do
      {:ok, %{peer_token: token, label: label, app_port: 0}}
    else
      _ -> {:error, :invalid_peer_open}
    end
  end

  def peer_open_request(_), do: {:error, :invalid_peer_open}

  @spec peer_open_response(term(), binary(), binary()) ::
          {:ok, %{attestation: map(), grant: map()}} | {:error, :invalid_peer_open}
  def peer_open_response(
        %{"version" => 1, "attestation" => attestation, "grant" => grant} = envelope,
        host,
        label
      )
      when map_size(envelope) == 3 do
    with {:ok, attestation} <- peer_attestation(attestation),
         {:ok, grant} <-
           OverallsProtocol.WebStream.response(
             "web-open",
             %{"version" => 1, "grant" => grant},
             host,
             label
           ) do
      {:ok, %{attestation: attestation, grant: grant}}
    else
      _ -> {:error, :invalid_peer_open}
    end
  end

  def peer_open_response(_, _, _), do: {:error, :invalid_peer_open}

  @spec headers(term()) :: {:ok, [{binary(), binary()}]} | :error
  defp headers(pairs) when is_list(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn pair, {:ok, acc} ->
      case header(pair) do
        {:ok, header} -> {:cont, {:ok, [header | acc]}}
        {:error, _} -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      :error -> :error
    end
  end

  defp headers(_), do: :error

  defp peer(nil), do: {:ok, nil}

  defp peer(value) when is_map(value) and map_size(value) == 2 do
    with {:ok, endpoint} <- target(value["endpoint"]),
         token <- value["token"],
         true <- is_binary(token) and byte_size(token) in 20..128 do
      {:ok, %{endpoint: endpoint, token: token}}
    else
      _ -> {:error, :invalid_peer}
    end
  end

  defp peer(_), do: {:error, :invalid_peer}
end
