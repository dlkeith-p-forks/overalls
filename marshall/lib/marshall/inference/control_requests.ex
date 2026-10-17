defmodule Marshall.Inference.ControlRequests do
  @moduledoc """
  Ziggy's closed control requests over the control WebSocket (ADR-0142).

  Every domain call authenticates the host credential again inside its own
  transaction, so rotation and revocation apply to the next request.
  Documents arrive with their version envelope already removed.
  """

  @routes [
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
    "agent_next",
    "agent_result",
    "ssh_roster",
    "ssh_authorized_keys",
    "ssh_host_certificate",
    "ssh_authorize",
    "ssh_login"
  ]

  @doc "The routes both transports serve."
  @spec routes() :: [String.t()]
  def routes, do: @routes

  @doc "Handles one unversioned request document for `route`."
  @spec handle(String.t(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def handle(route, token, input) when route in @routes and is_map(input),
    do: dispatch(route, token, input)

  def handle(_route, _token, _input), do: {:error, :invalid_request}

  defp dispatch("identity", token, input) when map_size(input) == 0,
    do: Marshall.Inference.Requests.identity(token)

  defp dispatch("authorize", token, input),
    do: Marshall.Inference.Requests.authorize(token, input)

  defp dispatch("update_authorize", token, input),
    do: Marshall.Inference.Requests.authorize_update(token, input)

  defp dispatch("admit", token, input), do: Marshall.Inference.Requests.admit(token, input)

  defp dispatch("renew", token, %{"request_id" => id} = input) when map_size(input) == 1,
    do: Marshall.Inference.Requests.renew(token, id)

  defp dispatch("complete", token, %{"request_id" => id, "completion" => completion} = input)
       when map_size(input) == 2,
       do: Marshall.Inference.Requests.complete(token, id, completion)

  defp dispatch("agent_next", token, input) when map_size(input) == 0,
    do: Marshall.Agents.ModelCalls.claim(token)

  defp dispatch(
         "agent_result",
         token,
         %{"call_id" => id, "claim_id" => claim, "response" => response} = input
       )
       when map_size(input) == 3,
       do: Marshall.Agents.ModelCalls.complete(token, id, claim, response)

  defp dispatch("agent_" <> route, token, input),
    do: Marshall.Agents.ExecutorRPC.request(token, route, input)

  defp dispatch("ssh_host_certificate", token, %{"binding" => wire, "public_key" => key} = input)
       when map_size(input) == 2 do
    Marshall.SSH.host_certificate(%{role: :guest, token: token, public_key: key, binding: wire},
      actor: Marshall.Authorization.SystemActor.compute()
    )
  end

  defp dispatch("ssh_roster", token, %{"binding" => wire} = input) when map_size(input) == 1,
    do: Marshall.SSH.GuestAccess.roster(token, wire)

  defp dispatch("ssh_authorized_keys", token, %{"binding" => wire} = input)
       when map_size(input) == 1,
       do: Marshall.SSH.GuestAccess.authorized_keys(token, wire)

  defp dispatch(
         "ssh_authorize",
         token,
         %{"binding" => wire, "username" => username, "public_key" => key} = input
       )
       when map_size(input) == 3 and is_binary(username) and is_binary(key),
       do: Marshall.SSH.GuestAccess.authorize(token, wire, key, username)

  defp dispatch(
         "ssh_login",
         token,
         %{"binding" => wire, "username" => username, "public_key" => key} = input
       )
       when map_size(input) == 3 and is_binary(username) and is_binary(key),
       do: Marshall.SSH.GuestAccess.login(token, wire, key, username)

  defp dispatch(_, _, _), do: {:error, :invalid_request}
end
