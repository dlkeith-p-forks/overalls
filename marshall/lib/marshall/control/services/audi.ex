defmodule Marshall.Control.Services.Audi do
  @moduledoc """
  Audi gateways and DNS replicas over the control WebSocket (ADR-0142).

  Requests carry the closed versioned `OverallsProtocol` documents and run
  through `Marshall.Ingress.ControlRequests`, so every domain action
  authenticates the credential again under its own lock and rotation or
  revocation takes effect on the next request. Errors keep the HTTPS denial
  classes; everything else is uniformly unavailable.
  """
  @behaviour Marshall.Control.Service
  require Marshall.Events

  alias Marshall.Authorization.SystemActor
  alias Marshall.Ingress.ControlRequests

  @token_bytes 56
  # The DNS snapshot may reach 8 MiB and the gateway catalog 4 MiB; every
  # stream lease renews over the same socket.
  @limits %{frame: 8_388_608 + 1_024, in_flight: 64}
  @named_errors [
    :capacity,
    :session_limit,
    :host_key_conflict,
    :invalid_request,
    :unsupported_version,
    :message_too_large
  ]

  @impl true
  def authenticate(token) when is_binary(token) and byte_size(token) == @token_bytes do
    case Marshall.Ingress.service_identity(%{token: token}, actor: SystemActor.compute()) do
      {:ok, %{id: id, role: role, host_id: host_id}} ->
        {:ok, %{token: token, service_id: id, role: role, host_id: host_id}}

      _ ->
        :refused
    end
  end

  def authenticate(_token), do: :refused

  # @cc [owner:ghuntley,label:security] control-audi-bind
  # An Audi hello MUST name exactly the role and host its credential holds
  # (`host_id` null for DNS); any other bind closes as refused before a request
  # or hint is served. The socket subscribes only to its own service's hints.
  @impl true
  def bind(principal, %{"role" => role, "host_id" => host_id} = bind) when map_size(bind) == 2 do
    if role == Atom.to_string(principal.role) and host_id == principal.host_id,
      do: {:ok, principal, subscriptions(principal)},
      else: {:close, :refused}
  end

  def bind(_principal, _bind), do: {:close, :refused}

  # A gateway also hears its host's route-catalog hints, and every user and VM
  # authority hint, so the stream leases it holds renew (or end) at once.
  @spec subscriptions(map()) :: [{Marshall.Control.Hints.kind(), String.t() | :all}]
  defp subscriptions(%{role: :gateway, host_id: host_id} = principal) when is_binary(host_id),
    do: [
      {:service, principal.service_id},
      {:gateway_catalog, host_id},
      {:user, :all},
      {:vm, :all},
      {:fleet_certificate, :all}
    ]

  # A DNS replica hears every zone hint; the snapshot is zone-wide.
  defp subscriptions(%{role: :dns} = principal),
    do: [{:service, principal.service_id}, {:dns_snapshot, :all}]

  defp subscriptions(principal), do: [{:service, principal.service_id}]

  @impl true
  def limits, do: @limits

  # Op names carry the HTTPS route with underscores (`audi.web_open`).
  @impl true
  def handle_request("audi." <> name, body, %{token: token}) do
    case ControlRequests.handle(String.replace(name, "_", "-"), token, body) do
      {:ok, value} -> {:ok, value |> Jason.encode!() |> Jason.decode!()}
      result -> {:error, error_name(result)}
    end
  end

  def handle_request(_op, _body, _identity), do: {:error, "invalid_request"}

  # @cc [owner:ghuntley,label:security;protocol] control-audi-denial-classes
  # Socket errors MUST keep the HTTPS denial classes Audi relies on:
  # authentication_required, unauthorized and forbidden stay distinct, the
  # named client errors keep their names, and every other result is the
  # uniform "unavailable" with only a closed reason class recorded.
  @spec error_name(term()) :: String.t()
  defp error_name({:error, reason}) when reason in [:authentication_required, :unauthorized] do
    Marshall.Events.emit("api.request_unauthorized", reason: reason)
    Atom.to_string(reason)
  end

  defp error_name({:error, reason}) when reason in [:forbidden, :vm_deleted], do: "forbidden"
  defp error_name({:error, reason}) when reason in @named_errors, do: Atom.to_string(reason)

  defp error_name(result) do
    ControlRequests.unavailable(result)
    "unavailable"
  end
end
