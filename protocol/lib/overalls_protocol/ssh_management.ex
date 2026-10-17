defmodule OverallsProtocol.SSHManagement do
  @moduledoc "Closed Porsche-to-Marshall session envelopes, independent of provisioner control versions."
  @spec request(binary(), term()) :: {:ok, map()} | {:error, atom()}

  # @cc [owner:ghuntley,label:protocol;security] ssh-management-session-envelope
  # Requests MUST contain only the fields belonging to their explicit v1 route.
  # No actor, owner or privilege supplied by a gateway message may be accepted.
  # Credential syntax is bounded here; durable authority belongs to Marshall.
  def request("ready", %{"version" => 1} = value) when map_size(value) == 1,
    do: {:ok, %{}}

  def request("sessions", %{"version" => 1, "public_key" => text} = value)
      when map_size(value) == 2 do
    case OverallsProtocol.SSHKey.parse(text) do
      {:ok, key} -> {:ok, %{public_key: key.public_key}}
      _ -> {:error, :invalid_public_key}
    end
  end

  def request(route, %{"version" => 1, "session_token" => token} = value)
      when route in ["session", "close"] and map_size(value) == 2 and is_binary(token) and
             byte_size(token) in 1..80 do
    {:ok, %{session_token: token}}
  end

  def request(
        "commands",
        %{"version" => 1, "session_token" => token, "command" => command} = value
      )
      when map_size(value) == 3 and is_binary(token) and byte_size(token) in 1..80 do
    case OverallsProtocol.SSHCommand.validate(command) do
      {:ok, _} -> {:ok, %{session_token: token, command: command}}
      _ -> {:error, :invalid_command}
    end
  end

  def request(_, %{"version" => version}) when version != 1, do: {:error, :unsupported_version}
  def request(_, _), do: {:error, :invalid_request}
end
