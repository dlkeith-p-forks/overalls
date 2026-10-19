defmodule Marshall.Control.Services.Porsche do
  @moduledoc """
  Porsche's gateway requests over the control WebSocket (ADR-0142).

  Requests carry the versioned gateway documents (only `ready` and
  `host-certificate` remain `/api/ssh/v1` HTTPS routes) and run through
  `Marshall.SSH.ControlRequests`; every action authenticates the gateway
  credential again. Errors carry the same closed names the HTTPS bodies did,
  each belonging to exactly one status class.
  """
  @behaviour Marshall.Control.Service

  alias Marshall.SSH.{Authority, ControlRequests}

  # Up to 4096 gateway connections may each wait on one session or command.
  @limits %{in_flight: 256}

  @impl true
  def authenticate(token) when is_binary(token) and byte_size(token) <= 80 do
    case Authority.gateway_identity(token) do
      {:ok, %{id: id, generation: generation}} ->
        {:ok, %{token: token, gateway_id: id, generation: generation}}

      _ ->
        :refused
    end
  end

  def authenticate(_token), do: :refused

  # @cc [owner:ghuntley,label:security] control-porsche-bind
  # A Porsche hello MUST carry an empty bind; the identity is the gateway its
  # credential names. The socket subscribes to that gateway's service hints and,
  # for `watch` streams (ADR-0222), to every machine, thread, terminal-session
  # and SSH-session hint. Hints carry only a closed kind and a UUID and are never
  # authority: Porsche routes them only to watchers whose subscription Marshall
  # authorized, and every watcher re-reads through authorized commands.
  @impl true
  def bind(principal, bind) when map_size(bind) == 0,
    do:
      {:ok, principal,
       [
         {:service, principal.gateway_id},
         {:vm, :all},
         {:thread, :all},
         {:terminal_session, :all},
         {:ssh_session, :all}
       ]}

  def bind(_principal, _bind), do: {:close, :refused}

  @impl true
  def limits, do: @limits

  @impl true
  def handle_request("porsche." <> route, body, %{token: token}) do
    case route |> ControlRequests.handle(token, body) |> ControlRequests.classify() do
      {:ok, value} -> {:ok, value |> Jason.encode!() |> Jason.decode!()}
      {:error, _status, name} -> {:error, name}
    end
  end

  def handle_request(_op, _body, _identity), do: {:error, "invalid_request"}
end
