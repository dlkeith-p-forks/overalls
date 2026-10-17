defmodule Audi.Control.Client do
  @moduledoc """
  Audi's requests to Marshall over the control WebSocket (ADR-0142), with role
  and host binding.

  The struct names the `OverallsProtocol.Control.Client` that
  `Audi.Control.Link` owns; requests carry the same versioned documents and
  decoders as before, and failures keep their fixed reason classes.
  """
  require Audi.Events
  @derive {Inspect, except: [:token]}
  @enforce_keys [:origin, :token, :role]
  defstruct [:origin, :token, :role, :host_id, :cacertfile, control: Audi.ControlClient]
  @maximum 4096
  @deadline 3_000
  @type t :: %__MODULE__{
          origin: binary(),
          token: binary(),
          role: :dns | :gateway,
          host_id: binary() | nil,
          cacertfile: binary() | nil,
          control: GenServer.server()
        }
  @type error ::
          :invalid_configuration
          | :transport_error
          | :unauthorized
          | :forbidden
          | :authentication_required
          | :invalid_message
          | :message_too_large
          | :http_error
          | :unsupported_version
          | :binding_mismatch
          | :expired_response

  # @cc [owner:ghuntley,label:security] audi-control-ipv4-only
  # Control origins MUST reject IPv6 literals. Outbound transport MUST disable
  # IPv6 even when the configured DNS hostname has both address families.
  @spec new(binary(), binary(), :dns | :gateway, keyword()) ::
          {:ok, t()} | {:error, :invalid_configuration}
  def new(origin, token, role, options \\ []) do
    with true <- is_binary(origin) and byte_size(origin) <= 2048,
         true <-
           is_binary(token) and byte_size(token) == 56 and
             String.starts_with?(token, "audi_service_"),
         {:ok, uri} <- URI.new(origin),
         true <-
           uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
             not String.contains?(uri.host, ":") and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
             uri.path in [nil, "/"],
         host_id = Keyword.get(options, :host_id),
         true <-
           (role == :dns and is_nil(host_id)) or
             (role == :gateway and OverallsProtocol.uuid?(host_id)),
         ca = Keyword.get(options, :cacertfile),
         true <- is_nil(ca) or is_binary(ca),
         control = Keyword.get(options, :control, Audi.ControlClient),
         true <- is_atom(control) do
      {:ok,
       %__MODULE__{
         origin: String.trim_trailing(origin, "/"),
         token: token,
         role: role,
         host_id: host_id,
         cacertfile: ca,
         control: control
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  @spec identity(t()) :: {:ok, map()} | {:error, error()}
  def identity(client), do: exchange(client, "identity", %{}, &identity_response(&1, client))

  # @cc [owner:ghuntley,label:security] audi-peer-token-verification
  # Only a gateway may present an opaque peer token. The request and response
  # MUST use the shared closed schema and bind the independently admitted grant
  # to the selected destination. Failed exchanges are never retried or
  # interpreted as ordinary guest authorization.
  @spec open_peer(t(), binary(), 0, binary()) :: {:ok, map()} | {:error, error()}
  def open_peer(%{role: :gateway} = client, label, 0, token) do
    started = System.monotonic_time(:millisecond)
    wire = %{"version" => 1, "peer_token" => token, "label" => label, "app_port" => 0}

    with {:ok, request} <- OverallsProtocol.Integration.peer_open_request(wire),
         {:ok, %{attestation: attestation, grant: grant}} <-
           exchange(
             client,
             "galileo-peer",
             request,
             &OverallsProtocol.Integration.peer_open_response(&1, client.host_id, label)
           ),
         {:ok, grant} <- with_deadline(grant, started) do
      {:ok, %{attestation: attestation, grant: grant}}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_message}
    end
  end

  def open_peer(_, _, _, _), do: {:error, :binding_mismatch}

  @spec begin_web_login(t(), binary(), integer(), binary(), binary()) ::
          {:ok, map()} | {:error, error()}
  def begin_web_login(client, label, port, state, hostname) do
    if OverallsProtocol.WebLogin.state?(state) do
      browser_exchange(
        client,
        "web-login-begin",
        %{
          label: label,
          app_port: port,
          state_digest: Base.encode16(:crypto.hash(:sha256, state), case: :lower)
        },
        hostname
      )
    else
      {:error, :invalid_message}
    end
  end

  @spec exchange_web_login(t(), binary(), binary(), binary(), binary()) ::
          {:ok, map()} | {:error, error()}
  def exchange_web_login(client, ticket, code, state, hostname),
    do:
      browser_exchange(
        client,
        "web-login-exchange",
        %{ticket: ticket, code: code, state: state},
        hostname
      )

  # @cc [owner:ghuntley,label:security] audi-browser-exchange-origin
  # Browser exchange MUST use the configured gateway control origin and closed
  # shared schema. Replies MUST bind the expected TLS hostname and token purpose.
  # Neither reply nor a gateway credential may approve the logged-in user.
  defp browser_exchange(%{role: :gateway} = client, route, message, hostname) do
    wire = Map.new(message, fn {key, value} -> {Atom.to_string(key), value} end)

    with {:ok, _, _} <- OverallsProtocol.WebLogin.request(route, Map.put(wire, "version", 1)),
         do:
           exchange(
             client,
             route,
             message,
             &OverallsProtocol.WebLogin.response(route, &1, hostname)
           ),
         else: (_ -> {:error, :invalid_message})
  end

  defp browser_exchange(_, _, _, _), do: {:error, :binding_mismatch}

  @spec report_ready_route(t(), map()) :: {:ok, map()} | {:error, error()}
  def report_ready_route(%{role: :gateway} = client, request) when is_map(request) do
    with true <- Enum.all?(Map.keys(request), &is_atom/1),
         wire = Map.new(request, fn {key, value} -> {Atom.to_string(key), value} end),
         {:ok, _} <- OverallsProtocol.IngressRoute.request(Map.put(wire, "version", 1)) do
      exchange(client, "route-ready", request, fn value ->
        with {:ok, result} <- OverallsProtocol.IngressRoute.response(value),
             true <-
               result.certificate_fingerprint == request.certificate_fingerprint and
                 String.ends_with?(
                   result.label,
                   request.vm_id |> String.downcase() |> String.replace("-", "")
                 ) do
          {:ok, result}
        else
          {:error, _} = error -> error
          _ -> {:error, :binding_mismatch}
        end
      end)
    else
      _ -> {:error, :invalid_message}
    end
  end

  def report_ready_route(_, _), do: {:error, :binding_mismatch}

  @spec gateway_catalog(t()) :: {:ok, map()} | {:error, error()}
  def gateway_catalog(%{role: :gateway} = client) do
    started = System.monotonic_time(:millisecond)

    with {:ok, catalog} <-
           exchange(
             client,
             "gateway-catalog",
             %{},
             &OverallsProtocol.IngressCatalog.decode/1,
             4_194_304
           ),
         true <- catalog.host_id == client.host_id do
      expires = started + catalog.ttl

      if expires > System.monotonic_time(:millisecond),
        do: {:ok, catalog |> Map.delete(:ttl) |> Map.put(:expires_at, expires)},
        else: {:error, :expired_response}
    else
      {:error, _} = error -> error
      _ -> {:error, :binding_mismatch}
    end
  end

  def gateway_catalog(_), do: {:error, :binding_mismatch}

  # @cc [owner:ghuntley,label:security] audi-fleet-certificate-client-binding
  # Only a gateway credential may fetch a bundle. The response MUST bind its
  # configured host and zone before passing secret bytes to the TLS validator.
  # Acknowledgement MUST follow a local verified listener probe.
  @spec fleet_certificate(t(), binary()) ::
          {:ok, OverallsProtocol.FleetCertificate.bundle()} | {:error, error()}
  def fleet_certificate(%{role: :gateway} = client, zone) when is_binary(zone) do
    exchange(
      client,
      "fleet-certificate",
      %{},
      &OverallsProtocol.FleetCertificate.response("fleet-certificate", &1, client.host_id, zone),
      1_048_576
    )
  end

  def fleet_certificate(_, _), do: {:error, :binding_mismatch}

  @spec acknowledge_fleet_certificate(t(), binary(), pos_integer(), binary()) ::
          {:ok, map()} | {:error, error()}
  def acknowledge_fleet_certificate(%{role: :gateway} = client, zone, generation, fingerprint) do
    request = %{generation: generation, fingerprint: fingerprint}
    wire = %{"version" => 1, "generation" => generation, "fingerprint" => fingerprint}

    with {:ok, _} <- OverallsProtocol.FleetCertificate.request("fleet-certificate-ack", wire),
         {:ok, %{generation: ^generation} = ack} <-
           exchange(
             client,
             "fleet-certificate-ack",
             request,
             &OverallsProtocol.FleetCertificate.response(
               "fleet-certificate-ack",
               &1,
               client.host_id,
               zone
             )
           ) do
      {:ok, ack}
    else
      {:error, _} = error -> error
      _ -> {:error, :binding_mismatch}
    end
  end

  def acknowledge_fleet_certificate(_, _, _, _), do: {:error, :binding_mismatch}

  @spec dns_snapshot(t(), binary()) :: {:ok, Audi.DNS.Snapshot.t()} | {:error, error()}
  def dns_snapshot(%{role: :dns} = client, zone) when is_binary(zone) do
    started = System.monotonic_time(:millisecond)

    exchange(
      client,
      "dns-snapshot",
      %{zone: zone},
      &Audi.DNS.Snapshot.decode(&1, zone, started),
      8_388_608
    )
  end

  def dns_snapshot(_, _), do: {:error, :binding_mismatch}

  @spec publish_host_key(t(), binary()) :: {:ok, map()} | {:error, error()}
  def publish_host_key(%{role: :gateway} = client, public_key) do
    case OverallsProtocol.SSHKey.parse(public_key) do
      {:ok, %{algorithm: "ssh-ed25519", public_key: ^public_key}} ->
        exchange(
          client,
          "host-key",
          %{public_key: public_key},
          &host_key_response(&1, client, public_key)
        )

      _ ->
        {:error, :invalid_message}
    end
  end

  def publish_host_key(_, _), do: {:error, :binding_mismatch}

  # @cc [owner:ghuntley,label:security] audi-host-key-publication-binding
  # The closed acknowledgement MUST bind this gateway's configured host and
  # exact public key. Publication never changes the local listener's identity.
  defp host_key_response(value, client, public_key) do
    with %{"version" => 1, "host_key" => key} when map_size(value) == 2 <- value,
         %{
           "service_id" => service,
           "host_id" => host,
           "generation" => generation,
           "public_key" => ^public_key
         }
         when map_size(key) == 4 <- key,
         true <-
           OverallsProtocol.uuid?(service) and host == client.host_id and
             is_integer(generation) and generation in 1..9_223_372_036_854_775_807 do
      {:ok, %{service_id: service, host_id: host, generation: generation, public_key: public_key}}
    else
      _ -> {:error, :binding_mismatch}
    end
  end

  @spec open_nested(t(), binary(), OverallsProtocol.InceptionName.service(), binary() | nil) ::
          {:ok, map()} | {:error, error()}
  def open_nested(client, label, service, key \\ nil),
    do:
      nested_exchange(
        client,
        "nested-open",
        %{label: label, nested_service: service, public_key: key},
        %{host_id: client.host_id, label: label, service: service},
        nil
      )

  @spec renew_nested(t(), binary(), map()) :: {:ok, map()} | {:error, error()}
  def renew_nested(client, ticket, previous),
    do:
      nested_exchange(client, "nested-renew", %{stream_token: ticket}, previous.binding, previous)

  @spec close_nested(t(), binary()) :: {:ok, map()} | {:error, error()}
  def close_nested(client, ticket),
    do: nested_exchange(client, "nested-close", %{stream_token: ticket}, %{}, nil)

  # @cc [owner:ghuntley,label:security] audi-nested-request-deadline
  # Nested grants MUST expire relative to request start and retain the complete
  # binding and host key on renewal. A late response MUST NOT refresh authority.
  defp nested_exchange(%{role: :gateway} = client, route, message, expected, previous) do
    started = System.monotonic_time(:millisecond)
    wire = message |> JSON.encode!() |> JSON.decode!() |> Map.put("version", 1)

    with {:ok, _, _} <- OverallsProtocol.NestedStream.request(route, wire),
         {:ok, result} <-
           exchange(
             client,
             route,
             message,
             &OverallsProtocol.NestedStream.response(route, &1, expected, previous)
           ) do
      if route == "nested-close" do
        {:ok, result}
      else
        expires = started + result.ttl

        if expires > System.monotonic_time(:millisecond),
          do:
            {:ok,
             result
             |> Map.delete(:ttl)
             |> Map.put(:expires_at, expires)
             |> Map.put(:requested_at, started)},
          else: {:error, :expired_response}
      end
    end
  end

  defp nested_exchange(_, _, _, _, _), do: {:error, :binding_mismatch}

  @spec open_web(t(), binary(), integer(), binary() | nil) :: {:ok, map()} | {:error, error()}
  def open_web(client, label, app_port, cookie),
    do:
      web_exchange(
        client,
        "web-open",
        %{label: label, app_port: app_port, cookie: cookie},
        label,
        nil
      )

  @spec renew_web(t(), binary(), map()) :: {:ok, map()} | {:error, error()}
  def renew_web(client, ticket, previous),
    do:
      web_exchange(client, "web-renew", %{stream_token: ticket}, previous.binding.label, previous)

  @spec close_web(t(), binary()) :: {:ok, map()} | {:error, error()}
  def close_web(client, ticket),
    do: web_exchange(client, "web-close", %{stream_token: ticket}, "", nil)

  # @cc [owner:ghuntley,label:security] audi-web-request-start-deadline
  # Web grants MUST expire relative to request start, preserving complete binding
  # and identity on renewal. A late response MUST NOT extend a stream's authority.
  defp web_exchange(%{role: :gateway} = client, route, message, label, previous) do
    started = System.monotonic_time(:millisecond)
    wire = Map.new(message, fn {key, value} -> {Atom.to_string(key), value} end)

    with {:ok, _, _} <- OverallsProtocol.WebStream.request(route, Map.put(wire, "version", 1)),
         {:ok, result} <-
           exchange(
             client,
             route,
             message,
             &OverallsProtocol.WebStream.response(route, &1, client.host_id, label, previous)
           ) do
      if route == "web-close" do
        {:ok, result}
      else
        with_deadline(result, started)
      end
    end
  end

  defp web_exchange(_, _, _, _, _), do: {:error, :binding_mismatch}

  defp with_deadline(grant, started) do
    expires = started + grant.ttl

    if expires > System.monotonic_time(:millisecond),
      do:
        {:ok,
         grant
         |> Map.delete(:ttl)
         |> Map.put(:expires_at, expires)
         |> Map.put(:requested_at, started)},
      else: {:error, :expired_response}
  end

  @spec begin_editor_login(t(), binary(), binary(), binary()) :: {:ok, map()} | {:error, error()}
  def begin_editor_login(client, label, state, hostname) do
    if OverallsProtocol.EditorLogin.state?(state),
      do:
        editor_browser_exchange(
          client,
          "editor-login-begin",
          %{
            label: label,
            state_digest: Base.encode16(:crypto.hash(:sha256, state), case: :lower)
          },
          hostname
        ),
      else: {:error, :invalid_message}
  end

  @spec exchange_editor_login(t(), binary(), binary(), binary(), binary()) ::
          {:ok, map()} | {:error, error()}
  def exchange_editor_login(client, ticket, code, state, hostname),
    do:
      editor_browser_exchange(
        client,
        "editor-login-exchange",
        %{ticket: ticket, code: code, state: state},
        hostname
      )

  defp editor_browser_exchange(%{role: :gateway} = client, route, message, hostname) do
    wire =
      Map.new(message, fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("version", 1)

    with {:ok, _, _} <- OverallsProtocol.EditorLogin.request(route, wire),
         do:
           exchange(
             client,
             route,
             message,
             &OverallsProtocol.EditorLogin.response(route, &1, hostname)
           ),
         else: (_ -> {:error, :invalid_message})
  end

  defp editor_browser_exchange(_, _, _, _), do: {:error, :binding_mismatch}

  @spec open_editor(t(), binary(), binary() | nil) :: {:ok, map()} | {:error, error()}
  def open_editor(client, label, cookie),
    do: editor_exchange(client, "editor-open", %{label: label, cookie: cookie}, label, nil)

  @spec renew_editor(t(), binary(), map()) :: {:ok, map()} | {:error, error()}
  def renew_editor(client, ticket, previous),
    do:
      editor_exchange(
        client,
        "editor-renew",
        %{stream_token: ticket},
        previous.binding.label,
        previous
      )

  @spec close_editor(t(), binary()) :: {:ok, map()} | {:error, error()}
  def close_editor(client, ticket),
    do: editor_exchange(client, "editor-close", %{stream_token: ticket}, "", nil)

  # @cc [owner:ghuntley,label:security] audi-editor-request-start-deadline
  # Editor grants MUST use their own closed codec, binding and token purpose.
  # Deadlines derive from request start; renewal MUST retain the whole binding.
  defp editor_exchange(%{role: :gateway} = client, route, message, label, previous) do
    started = System.monotonic_time(:millisecond)

    wire =
      Map.new(message, fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("version", 1)

    with {:ok, _, _} <- OverallsProtocol.EditorStream.request(route, wire),
         {:ok, result} <-
           exchange(
             client,
             route,
             message,
             &OverallsProtocol.EditorStream.response(route, &1, client.host_id, label, previous)
           ) do
      if route == "editor-close", do: {:ok, result}, else: with_deadline(result, started)
    end
  end

  defp editor_exchange(_, _, _, _, _), do: {:error, :binding_mismatch}

  @spec editor_assets_ready(t(), OverallsProtocol.EditorRelease.t()) ::
          {:ok, map()} | {:error, error()}
  def editor_assets_ready(%{role: :gateway} = client, descriptor) do
    message = %{
      editor_protocol: descriptor.protocol,
      editor_commit: descriptor.commit,
      editor_release: descriptor.release
    }

    exchange(
      client,
      "editor-assets-ready",
      message,
      &OverallsProtocol.EditorAssets.response(&1, descriptor)
    )
  end

  def editor_assets_ready(_, _), do: {:error, :binding_mismatch}

  @spec ssh_key_status(t(), binary()) ::
          {:ok, OverallsProtocol.SSHOnboarding.key_status()} | {:error, error()}
  def ssh_key_status(%{role: :gateway} = client, key) do
    with {:ok, parsed} <- OverallsProtocol.SSHKey.parse(key) do
      exchange(
        client,
        "ssh-key-status",
        %{public_key: parsed.public_key},
        &OverallsProtocol.SSHOnboarding.decode_status/1
      )
    else
      _ -> {:error, :invalid_message}
    end
  end

  def ssh_key_status(_, _), do: {:error, :binding_mismatch}

  @spec open_ssh(t(), binary(), binary()) :: {:ok, map()} | {:error, error()}
  def open_ssh(%{role: :gateway} = client, key, label) do
    with {:ok, parsed} <- OverallsProtocol.SSHKey.parse(key),
         true <- OverallsProtocol.IngressName.valid_label?(label) do
      exchange(
        client,
        "ssh-open",
        %{public_key: parsed.public_key, label: label},
        &grant_response(&1, client, label, nil)
      )
    else
      _ -> {:error, :invalid_message}
    end
  end

  def open_ssh(_, _, _), do: {:error, :binding_mismatch}

  @spec renew_ssh(t(), binary(), map()) :: {:ok, map()} | {:error, error()}
  def renew_ssh(%{role: :gateway} = client, ticket, binding) when is_map(binding) do
    if session_token?(ticket) do
      exchange(client, "ssh-renew", %{session_token: ticket}, fn message ->
        with {:ok, grant} <- grant_response(message, client, Map.get(binding, :label), ticket),
             true <- grant.binding == binding do
          {:ok, Map.delete(grant, :ticket)}
        else
          {:error, _} = error -> error
          _ -> {:error, :binding_mismatch}
        end
      end)
    else
      {:error, :invalid_message}
    end
  end

  def renew_ssh(_, _, _), do: {:error, :binding_mismatch}

  @spec close_ssh(t(), binary()) :: {:ok, map()} | {:error, error()}
  def close_ssh(%{role: :gateway} = client, ticket) do
    if session_token?(ticket) do
      exchange(client, "ssh-close", %{session_token: ticket}, fn
        %{"version" => 1, "result" => %{"closed" => true} = result} = value
        when map_size(value) == 2 and map_size(result) == 1 ->
          {:ok, %{closed: true}}

        _ ->
          {:error, :invalid_message}
      end)
    else
      {:error, :invalid_message}
    end
  end

  def close_ssh(_, _), do: {:error, :binding_mismatch}

  # @cc [owner:ghuntley,label:security] audi-https-control-bounds
  # Credentials MUST be sent only to the configured verified HTTPS origin, over
  # the control WebSocket. Requests are never retried or queued, responses and
  # deadlines are bounded, and response role/host are checked against local
  # configuration. Failures MUST expose only fixed reasons, never requests or
  # credentials.
  defp exchange(client, route, message, decode, maximum \\ @maximum) do
    client.control
    |> OverallsProtocol.Control.Client.request(
      "audi." <> String.replace(route, "-", "_"),
      Map.put(message, :version, 1),
      @deadline
    )
    |> response(client, decode, maximum)
    |> case do
      {:ok, _} = success ->
        success

      {:error, reason} = failure when is_atom(reason) ->
        exchange_failed(client, reason)
        failure
    end
  rescue
    _ ->
      exchange_failed(client, :transport_error)
      {:error, :transport_error}
  catch
    _, _ ->
      exchange_failed(client, :transport_error)
      {:error, :transport_error}
  end

  defp exchange_failed(%{host_id: nil}, reason),
    do: Audi.Events.emit("audi.control_exchange_failed", reason: reason)

  defp exchange_failed(%{host_id: host_id}, reason) when is_binary(host_id),
    do: Audi.Events.emit("audi.control_exchange_failed", host_id: host_id, reason: reason)

  @spec response(
          {:ok, map()} | {:error, OverallsProtocol.Control.Client.request_error()},
          t(),
          (map() -> {:ok, map()} | {:error, error()}),
          pos_integer()
        ) :: {:ok, map()} | {:error, error()}
  defp response({:ok, value}, _client, decode, maximum) do
    if byte_size(JSON.encode!(value)) <= maximum,
      do: decode.(value),
      else: {:error, :message_too_large}
  end

  # @cc [owner:ghuntley,label:security] audi-control-denial-classes
  # Control denials MUST remain distinct: authentication_required is a missing
  # browser identity, forbidden an explicit membership/VM denial, and
  # unauthorized missing route or execution authority. Callers MUST NOT
  # collapse these classes, and no denial may be retried as success.
  defp response({:error, "authentication_required"}, _, _, _),
    do: {:error, :authentication_required}

  defp response({:error, "unauthorized"}, _, _, _), do: {:error, :unauthorized}
  defp response({:error, "forbidden"}, _, _, _), do: {:error, :forbidden}
  defp response({:error, "message_too_large"}, _, _, _), do: {:error, :message_too_large}

  # @cc [owner:ghuntley,label:protocol;recovery] audi-terminal-version-refusal
  # A version refusal (HTTP 426 at upgrade, close 4001, or a refused request
  # version) MUST keep its terminal class; transient transport and service
  # failures keep their separate classes.
  defp response({:error, "unsupported_version"}, _, _, _), do: {:error, :unsupported_version}
  defp response({:error, reason}, _, _, _) when is_binary(reason), do: {:error, :http_error}

  # @cc [owner:ghuntley,label:protocol;recovery] audi-pending-terminal-version-refusal
  # An unproven pending exchange MUST retain unsupported_version when the
  # current control client holds that terminal refusal. Other connection loss
  # MUST remain transport_error; classification MUST NOT resend the request or
  # claim its domain effect completed.
  defp response({:error, reason}, client, _, _) when reason in [:disconnected, :unproven] do
    case OverallsProtocol.Control.Client.status(client.control) do
      {:disconnected, :unsupported_version} -> {:error, :unsupported_version}
      _ -> {:error, :transport_error}
    end
  end

  defp response({:error, _reason}, _, _, _), do: {:error, :transport_error}

  defp identity_response(value, client) do
    with %{"version" => 1, "service" => service} = envelope when map_size(envelope) == 2 <- value,
         %{
           "id" => id,
           "name" => name,
           "role" => role,
           "host_id" => host,
           "generation" => generation,
           "enabled" => true
         }
         when map_size(service) == 6 <- service,
         true <-
           OverallsProtocol.uuid?(id) and is_binary(name) and byte_size(name) in 1..128 and
             is_integer(generation) and generation > 0,
         true <- role in ["dns", "gateway"] and (is_nil(host) or OverallsProtocol.uuid?(host)) do
      if role == Atom.to_string(client.role) and host == client.host_id,
        do:
          {:ok, %{id: id, name: name, role: client.role, host_id: host, generation: generation}},
        else: {:error, :binding_mismatch}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # @cc [owner:ghuntley,label:security] audi-ssh-response-binding
  # SSH grants MUST use closed envelopes and bind this gateway's host, the
  # requested label and the complete immutable execution/session identity.
  # Renewal MUST preserve that complete binding; peer strings MUST NOT create atoms.
  defp grant_response(value, client, label, existing_ticket) do
    with %{"version" => 1, "grant" => grant} when map_size(value) == 2 <- value,
         user = if(is_map(grant), do: grant["user_id"]),
         true <-
           is_map(grant) and
             map_size(grant) ==
               if(is_nil(existing_ticket), do: 3, else: 2) +
                 if(Map.has_key?(grant, "user_id"), do: 1, else: 0),
         true <- is_nil(user) or OverallsProtocol.uuid?(user),
         %{"binding" => binding, "ttl" => ttl} <- grant,
         %{
           "vm_id" => vm,
           "host_id" => host,
           "placement_id" => placement,
           "session_id" => session,
           "execution_epoch" => epoch,
           "generation" => generation,
           "label" => returned_label,
           "service" => "ssh",
           "port" => 22
         }
         when map_size(binding) == 9 <- binding,
         ticket = Map.get(grant, "ticket", existing_ticket),
         true <- session_token?(ticket),
         true <- is_integer(generation) and generation > 0 do
      normalized = %{
        binding: %{
          vm_id: vm,
          host_id: host,
          placement_id: placement,
          session_id: session,
          execution_epoch: epoch,
          generation: generation,
          label: returned_label,
          service: :ssh,
          port: 22
        },
        ticket: ticket,
        ttl: ttl,
        user_id: user
      }

      if Audi.SSH.Request.grant?(normalized, label, client.host_id),
        do: {:ok, normalized},
        else: {:error, :binding_mismatch}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp session_token?("audi_session_" <> encoded) when byte_size(encoded) == 43 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == encoded

      _ ->
        false
    end
  end

  defp session_token?(_), do: false
end
