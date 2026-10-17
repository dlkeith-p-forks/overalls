defmodule Marshall.Control.Services.Ziggy do
  @moduledoc """
  Ziggy's control requests over the control WebSocket (ADR-0142).

  Requests carry Ziggy v2 accounting and authority documents
  and run through `Marshall.Inference.ControlRequests`; every domain call
  re-authenticates the host credential inside its own transaction. Errors keep
  the former HTTPS classes: unauthorized, the two conflict names, a version refusal,
  and invalid_request for every other refusal.
  """
  @behaviour Marshall.Control.Service
  require Marshall.Events

  alias Marshall.Inference.ControlRequests

  # agent_result carries a model response up to 1,048,576 bytes inside its
  # envelope; guest requests, leases and agent calls share one socket.
  @limits %{frame: 1_048_576 + 4_096, inbound: 1_100_000 + 4_096, in_flight: 256}

  @impl true
  def authenticate(token) when is_binary(token) and byte_size(token) == 80 do
    case Marshall.Inference.Requests.identity(token) do
      {:ok, %{host_id: host_id}} -> {:ok, %{token: token, host_id: host_id}}
      _ -> :refused
    end
  end

  def authenticate(_token), do: :refused

  # @cc [owner:ghuntley,label:security] control-ziggy-bind
  # A Ziggy hello MUST name exactly the host its credential holds; any other
  # bind closes as refused before a request or hint is served.
  @impl true
  def bind(%{host_id: host_id} = principal, %{"host_id" => host_id} = bind)
      when map_size(bind) == 1,
      do: {:ok, principal, [{:host, host_id}, {:ziggy_work, host_id}]}

  def bind(_principal, _bind), do: {:close, :refused}

  @impl true
  def limits, do: @limits

  @impl true
  def handle_request("ziggy." <> route, %{"version" => 2} = body, %{token: token}) do
    case ControlRequests.handle(route, token, Map.delete(body, "version")) do
      {:ok, value} -> {:ok, value |> Jason.encode!() |> Jason.decode!()}
      result -> {:error, error_name(result)}
    end
  end

  def handle_request("ziggy." <> _route, %{"version" => _version}, _identity),
    do: {:error, "unsupported_version"}

  def handle_request(_op, _body, _identity), do: {:error, "invalid_request"}

  # @cc [owner:ghuntley,label:security;protocol] control-ziggy-error-classes
  # Socket errors MUST keep the HTTPS classes Ziggy relies on: unauthorized
  # (with its diagnostic), duplicate_request and completion_conflict by name,
  # and invalid_request for every other refusal.
  @spec error_name(term()) :: String.t()
  defp error_name({:error, reason}) when reason in [:duplicate_request, :completion_conflict],
    do: Atom.to_string(reason)

  defp error_name({:error, :unauthorized}) do
    Marshall.Events.emit("api.request_unauthorized", reason: :unauthorized)
    "unauthorized"
  end

  defp error_name(_result), do: "invalid_request"
end
