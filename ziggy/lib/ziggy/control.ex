defmodule Ziggy.Control do
  @moduledoc """
  Ziggy's requests to Marshall over the control WebSocket (ADR-0142); no
  inference retries. The config names the `OverallsProtocol.Control.Client`
  that `Ziggy.Control.Link` owns.
  """
  require Ziggy.Events

  @type t :: %{
          required(:origin) => binary(),
          required(:token) => binary(),
          required(:ca_file) => binary(),
          optional(:client) => GenServer.server()
        }
  @type result ::
          {:ok, map()}
          | {:error,
             :authority_unavailable | :unauthorized | :completion_conflict | :unsupported_version}
  @type request_fun :: (t(), binary(), map() -> result())
  # @cc [owner:ghuntley,label:security] ziggy-control-ipv4-transport
  # Authority calls MUST use the verified-TLS IPv4 control socket, including
  # for dual-stack DNS names, and are never retried or queued.

  # @cc [owner:ghuntley,label:recovery] ziggy-version-refusal-terminal
  # A version refusal from Marshall (HTTP 426 at upgrade, close 4001 or an
  # unsupported_version answer) MUST retain a distinct permanent class; it
  # MUST NOT become an outage retry result, including pending :unproven calls
  # retired when the owning socket stops for unsupported_version.
  @spec request(t(), binary(), map()) :: result()
  def request(config, route, body)
      when route in [
             "admit",
             "renew",
             "complete",
             "authorize",
             "update_authorize",
             "identity",
             "agent_register",
             "agent_heartbeat",
             "agent_claim",
             "agent_transition",
             "agent_attachment_transfer",
             "agent_maintenance_claim",
             "agent_maintenance_transition",
             "agent_maintenance_artifact",
             "agent_bootstrap_artifact",
             "agent_artifact_chunk",
             "agent_next",
             "agent_result",
             "ssh_roster",
             "ssh_authorized_keys",
             "ssh_host_certificate",
             "ssh_authorize",
             "ssh_login"
           ] do
    maximum =
      case route do
        "agent_next" -> 524_288
        "agent_attachment_transfer" -> 360_448
        _ -> 16_384
      end

    client = Map.get(config, :client, Ziggy.ControlClient)

    response =
      client
      |> OverallsProtocol.Control.Client.request(
        "ziggy." <> route,
        Map.put(body, "version", 2),
        5_000
      )
      |> socket_result(route, maximum, client)

    if response == {:error, :authority_unavailable},
      do: Ziggy.Events.emit("ziggy.control_exchange_failed", reason: route_reason(route))

    if response == {:error, :unsupported_version},
      do: Ziggy.Events.emit("ziggy.control_version_refused", reason: route_reason(route))

    response
  rescue
    _ ->
      Ziggy.Events.emit("ziggy.control_exchange_failed", reason: route_reason(route))
      {:error, :authority_unavailable}
  catch
    :exit, _ ->
      Ziggy.Events.emit("ziggy.control_exchange_failed", reason: route_reason(route))
      {:error, :authority_unavailable}
  end

  # @cc [owner:ghuntley,label:recovery] completion-conflict-class-visible
  # A durable completion conflict MUST retain its distinct class after
  # Marshall's answer. It is not a transient control-plane outage and its
  # unacknowledged spool entry must remain visible for operator recovery.
  @doc false
  @spec socket_result(term(), binary(), pos_integer(), GenServer.server()) :: result()
  def socket_result({:ok, object}, _route, maximum, _client) when is_map(object) do
    if byte_size(Jason.encode!(object)) <= maximum,
      do: {:ok, object},
      else: {:error, :authority_unavailable}
  end

  def socket_result({:error, "unauthorized"}, _route, _maximum, _client),
    do: {:error, :unauthorized}

  def socket_result({:error, "unsupported_version"}, _route, _maximum, _client),
    do: {:error, :unsupported_version}

  def socket_result({:error, "completion_conflict"}, "complete", _maximum, _client),
    do: {:error, :completion_conflict}

  def socket_result({:error, reason}, _route, _maximum, client)
      when reason in [:disconnected, :unproven] do
    case OverallsProtocol.Control.Client.status(client) do
      {:disconnected, :unsupported_version} -> {:error, :unsupported_version}
      _ -> {:error, :authority_unavailable}
    end
  end

  def socket_result(_result, _route, _maximum, _client), do: {:error, :authority_unavailable}

  defp route_reason("admit"), do: :admit
  defp route_reason("renew"), do: :renew
  defp route_reason("complete"), do: :complete
  defp route_reason("authorize"), do: :authorize
  defp route_reason("update_authorize"), do: :authorize
  defp route_reason("identity"), do: :identity
  defp route_reason("agent_register"), do: :agent_register
  defp route_reason("agent_heartbeat"), do: :agent_heartbeat
  defp route_reason("agent_claim"), do: :agent_claim
  defp route_reason("agent_transition"), do: :agent_transition
  defp route_reason("agent_attachment_transfer"), do: :agent_attachment_transfer
  defp route_reason("agent_maintenance_claim"), do: :agent_maintenance_claim
  defp route_reason("agent_maintenance_transition"), do: :agent_maintenance_transition
  defp route_reason("agent_bootstrap_artifact"), do: :agent_bootstrap_artifact
  defp route_reason("agent_maintenance_artifact"), do: :agent_maintenance_artifact
  defp route_reason("agent_artifact_chunk"), do: :agent_artifact_chunk
  defp route_reason("agent_next"), do: :agent_next
  defp route_reason("agent_result"), do: :agent_result
  defp route_reason("ssh_host_certificate"), do: :ssh_host_certificate
  defp route_reason("ssh_roster"), do: :ssh_roster
  defp route_reason("ssh_authorized_keys"), do: :ssh_authorized_keys
  defp route_reason("ssh_authorize"), do: :ssh_authorize
  defp route_reason("ssh_login"), do: :ssh_login
end
