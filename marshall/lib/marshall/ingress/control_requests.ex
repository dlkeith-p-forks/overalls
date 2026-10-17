defmodule Marshall.Ingress.ControlRequests do
  @moduledoc """
  Audi's closed control requests, shared by the control WebSocket (ADR-0142)
  and the remaining `/api/audi/v1` HTTPS routes (`identity`, `host-key`,
  `dns-snapshot`).

  Each request names a route and carries the service credential, which every
  domain action authenticates again under its own lock. Bodies are the closed
  versioned documents of `OverallsProtocol`; results are the same envelopes
  either transport returns.
  """
  require Marshall.Events

  @routes [
    "identity",
    "gateway-catalog",
    "web-login-begin",
    "web-login-exchange",
    "editor-login-begin",
    "editor-login-exchange",
    "editor-open",
    "editor-renew",
    "editor-close",
    "editor-assets-ready",
    "route-ready",
    "nested-open",
    "nested-renew",
    "nested-close",
    "web-open",
    "web-renew",
    "web-close",
    "ssh-key-status",
    "ssh-open",
    "ssh-renew",
    "ssh-close",
    "host-key",
    "dns-snapshot",
    "galileo-peer",
    "fleet-certificate",
    "fleet-certificate-ack"
  ]

  @unavailable_reasons [
    :unavailable,
    :temporarily_unavailable,
    :approval_unavailable,
    :image_unavailable,
    :key_unavailable,
    :invalid_binding,
    :invalid_state,
    :invalid_peer_token
  ]

  @doc "The routes both transports serve."
  @spec routes() :: [String.t()]
  def routes, do: @routes

  @doc "Closed reason classes recorded by the uniform unavailable diagnostic."
  @spec unavailable_reasons() :: [atom()]
  def unavailable_reasons, do: @unavailable_reasons ++ [:rejected, :unexpected]

  @doc """
  Handles one versioned request document for `route`. Domain errors arrive
  unwrapped to their reason atom where the domain names one.
  """
  @spec handle(String.t(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def handle(route, token, %{"version" => 1} = value) when route in @routes,
    do: route |> message(token, value) |> normalize()

  def handle(_route, _token, %{"version" => version}) when version != 1,
    do: {:error, :unsupported_version}

  def handle(_route, _token, _value), do: {:error, :invalid_request}

  # @cc [owner:ghuntley,label:observability;security] ingress-unavailable-reason-class
  # Every transport's uniform unavailable answer MUST record only a closed
  # reason class: a reviewed unavailable/binding atom, :rejected for any other
  # atom, or :unexpected for any other term. Error structs, tokens and request
  # data MUST NOT reach metadata.
  @doc "Records the diagnostic for a result answered as uniformly unavailable."
  @spec unavailable(term()) :: :ok
  def unavailable(result) do
    Marshall.Events.emit("audi.control_unavailable", reason: unavailable_reason(result))
    :ok
  end

  @spec normalize(term()) :: term()
  defp normalize({:error, %Marshall.Ingress.Error{reason: reason}}),
    do: normalize({:error, reason})

  defp normalize({:error, %Ash.Error.Invalid{errors: [error]}}), do: normalize({:error, error})
  defp normalize(result), do: result

  @spec unavailable_reason(term()) :: atom()
  defp unavailable_reason({:error, reason}) when reason in @unavailable_reasons, do: reason
  defp unavailable_reason({:error, reason}) when is_atom(reason), do: :rejected
  defp unavailable_reason(_), do: :unexpected

  defp message(route, token, value)
       when route in ["nested-open", "nested-renew", "nested-close"] do
    with {:ok, action, arguments} <- OverallsProtocol.NestedStream.request(route, value),
         do:
           invoke(
             action,
             Map.put(arguments, :service_token, token),
             if(route == "nested-close", do: :result, else: :grant)
           )
  end

  # @cc [owner:ghuntley,label:security] galileo-peer-gateway-verification
  # Only an authenticated gateway service may consume a peer token. The same
  # closed request MUST name the canonical destination, and success requires an
  # independently admitted web grant bound to that target. Denial is uniform.
  defp message("galileo-peer", token, value) do
    with {:ok, arguments} <- OverallsProtocol.Integration.peer_open_request(value),
         {:ok, %{attestation: attestation, grant: grant}} <-
           Marshall.Ingress.open_peer_web(Map.put(arguments, :service_token, token),
             actor: Marshall.Authorization.SystemActor.compute()
           ) do
      {:ok,
       %{
         "version" => 1,
         "attestation" => %{
           "purpose" => "galileo-peer",
           "source_vm_id" => attestation.source_vm_id,
           "name" => attestation.name,
           "expires_at" => attestation.expires_at
         },
         "grant" => grant
       }}
    else
      _ -> {:error, :invalid_peer_token}
    end
  end

  defp message("identity", token, value) when map_size(value) == 1,
    do: invoke(:service_identity, %{token: token}, :service)

  defp message("gateway-catalog", token, value) when map_size(value) == 1,
    do: invoke(:gateway_catalog, %{token: token}, :catalog)

  defp message(route, token, value)
       when route in ["fleet-certificate", "fleet-certificate-ack"] do
    with {:ok, arguments} <- OverallsProtocol.FleetCertificate.request(route, value) do
      action =
        if route == "fleet-certificate",
          do: :deliver_fleet_certificate,
          else: :acknowledge_fleet_certificate

      envelope = if route == "fleet-certificate", do: :bundle, else: :ack
      invoke(action, Map.put(arguments, :service_token, token), envelope)
    end
  end

  defp message("route-ready", token, value) do
    with {:ok, arguments} <- OverallsProtocol.IngressRoute.request(value),
         do: invoke(:report_ready_route, Map.put(arguments, :service_token, token), :route)
  end

  defp message(route, token, value) when route in ["web-login-begin", "web-login-exchange"] do
    with {:ok, action, arguments} <- OverallsProtocol.WebLogin.request(route, value),
         do: invoke(action, Map.put(arguments, :service_token, token), :login)
  end

  defp message(route, token, value)
       when route in ["editor-login-begin", "editor-login-exchange"] do
    with {:ok, action, arguments} <- OverallsProtocol.EditorLogin.request(route, value),
         do: invoke_editor(action, Map.put(arguments, :service_token, token), :login)
  end

  defp message("editor-assets-ready", token, value) do
    with {:ok, arguments} <- OverallsProtocol.EditorAssets.request(value),
         do: invoke(:report_editor_assets, Map.put(arguments, :service_token, token), :ready)
  end

  defp message(route, token, value)
       when route in ["editor-open", "editor-renew", "editor-close"] do
    with {:ok, action, arguments} <- OverallsProtocol.EditorStream.request(route, value),
         do:
           invoke_editor(
             action,
             Map.put(arguments, :service_token, token),
             if(route == "editor-close", do: :result, else: :grant)
           )
  end

  defp message(route, token, value) when route in ["web-open", "web-renew", "web-close"] do
    with {:ok, action, arguments} <- OverallsProtocol.WebStream.request(route, value),
         do:
           invoke(
             action,
             Map.put(arguments, :service_token, token),
             if(route == "web-close", do: :result, else: :grant)
           )
  end

  defp message("dns-snapshot", token, %{"zone" => zone} = value)
       when map_size(value) == 2 and is_binary(zone) and byte_size(zone) <= 189 do
    Marshall.Ingress.dns_snapshot(%{token: token, zone: zone},
      actor: Marshall.Authorization.SystemActor.compute()
    )
  end

  defp message("host-key", token, %{"public_key" => key} = value)
       when map_size(value) == 2 and is_binary(key) and byte_size(key) <= 128,
       do: invoke(:publish_host_key, %{token: token, public_key: key}, :host_key)

  defp message("ssh-key-status", token, %{"public_key" => key} = value)
       when map_size(value) == 2 and is_binary(key) and byte_size(key) <= 4096,
       do: invoke(:ssh_key_status, %{service_token: token, public_key: key}, :result)

  defp message("ssh-open", token, %{"public_key" => key, "label" => label} = value)
       when map_size(value) == 3 and is_binary(key) and byte_size(key) <= 4096 and
              is_binary(label) and byte_size(label) <= 63,
       do: invoke(:open_ssh, %{service_token: token, public_key: key, label: label}, :grant)

  defp message(route, token, %{"session_token" => session} = value)
       when route in ["ssh-renew", "ssh-close"] and map_size(value) == 2 and
              is_binary(session) and byte_size(session) <= 80 do
    action = if route == "ssh-renew", do: :renew_ssh, else: :close_ssh
    envelope = if route == "ssh-renew", do: :grant, else: :result
    invoke(action, %{service_token: token, session_token: session}, envelope)
  end

  defp message(_, _, _), do: {:error, :invalid_request}

  defp invoke(action, arguments, envelope) do
    case apply(Marshall.Ingress, action, [
           arguments,
           [actor: Marshall.Authorization.SystemActor.compute()]
         ]) do
      {:ok, value} -> {:ok, %{envelope => value, :version => 1}}
      other -> other
    end
  end

  @spec invoke_editor(atom(), map(), atom()) :: {:ok, map()} | {:error, term()}
  defp invoke_editor(action, arguments, envelope) do
    case apply(Marshall.Editor, action, [
           arguments,
           [actor: Marshall.Authorization.SystemActor.compute()]
         ]) do
      {:ok, value} -> {:ok, %{envelope => value, :version => 1}}
      other -> other
    end
  end
end
