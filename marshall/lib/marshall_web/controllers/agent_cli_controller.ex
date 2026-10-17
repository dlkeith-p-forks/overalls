defmodule MarshallWeb.AgentCLIController do
  @moduledoc "Small VM-scoped RPC surface for the browser-approved user CLI."
  # Prefix plus 64 lowercase hex digits of the 32-byte CLI secret.
  @bearer_bytes byte_size("overalls_agent_") + 64
  use MarshallWeb, :controller
  alias Marshall.Agents.{CLIAccess, Conversation}
  require Marshall.Events

  @spec session(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def session(conn, %{"vm_id" => vm_id}) do
    with {:ok, token} <- bearer(conn),
         {:ok, state} <- CLIAccess.session(vm_id, token) do
      status = if state == :pending, do: "pending", else: "approved"
      reply(conn, 200, %{status: status})
    else
      _ -> refuse(conn)
    end
  end

  def session(conn, _), do: reply(conn, 400, %{error: "invalid_request"})

  @spec threads(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def threads(conn, %{"vm_id" => vm_id}) do
    with {:ok, actor} <- actor(conn, vm_id),
         {:ok, threads} <- Conversation.list(vm_id, actor) do
      reply(conn, 200, %{
        threads:
          Enum.map(threads, fn thread ->
            %{id: thread.id, title: thread.title, parent_thread_id: thread.parent_thread_id}
          end)
      })
    else
      _ -> refuse(conn)
    end
  end

  def threads(conn, _), do: reply(conn, 400, %{error: "invalid_request"})

  # @cc [owner:ghuntley,label:security] agent-cli-current-authority
  # Every call rechecks current VM write access. The CLI supplies a thread ID
  # and idempotency key, but the domain coordinator validates both against the
  # VM and persists the wake, prompt and audit receipt together.
  @spec prompt(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def prompt(conn, _params) do
    case conn.body_params do
      %{
        "vm_id" => vm_id,
        "thread_id" => thread_id,
        "prompt" => prompt,
        "request_key" => request_key
      } = body
      when map_size(body) == 4 and is_binary(prompt) and byte_size(prompt) in 1..65_536 ->
        with {:ok, actor} <- actor(conn, vm_id),
             {:ok, _thread} <- thread_for_vm(thread_id, vm_id, actor),
             {:ok, result} <-
               Marshall.Agents.submit_prompt(
                 %{thread_id: thread_id, prompt: prompt, request_key: request_key},
                 actor: actor
               ) do
          reply(conn, 200, %{turn_id: result.turn_id, status: result.status})
        else
          _ -> refuse(conn)
        end

      _ ->
        reply(conn, 400, %{error: "invalid_request"})
    end
  end

  @spec turn(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def turn(conn, %{"vm_id" => vm_id, "turn_id" => turn_id}) do
    with {:ok, actor} <- actor(conn, vm_id),
         {:ok, result} <- Conversation.turn(turn_id, actor),
         {:ok, thread} <- turn_thread(turn_id, actor),
         {:ok, _thread} <- thread_for_vm(thread.id, vm_id, actor) do
      reply(conn, 200, result)
    else
      _ -> refuse(conn)
    end
  end

  def turn(conn, _), do: reply(conn, 400, %{error: "invalid_request"})

  defp turn_thread(turn_id, actor) do
    case Marshall.Compute.Ledger.read!(Marshall.Agents.Turn, id: turn_id) do
      [%{thread_id: thread_id}] -> Conversation.get_thread(thread_id, actor)
      _ -> {:error, :not_found}
    end
  end

  defp thread_for_vm(thread_id, vm_id, actor) do
    with {:ok, thread} <- Conversation.get_thread(thread_id, actor),
         [%Marshall.Agents.Root{vm_id: ^vm_id}] <-
           Marshall.Compute.Ledger.read!(Marshall.Agents.Root, id: thread.root_id) do
      {:ok, thread}
    else
      _ -> {:error, :machine_unavailable}
    end
  end

  defp actor(conn, vm_id) do
    with {:ok, token} <- bearer(conn), do: CLIAccess.authorize(vm_id, token)
  end

  # @cc [owner:ghuntley,label:security] agent-cli-denial-diagnostic
  # Every 403 from this surface MUST emit the catalogued API denial event with a
  # closed reason, matching the sibling fleet/SSH/inference/provisioner/ingress
  # surfaces; the wire body stays a fixed error code without authority details.
  defp refuse(conn) do
    Marshall.Events.emit("api.request_unauthorized", reason: :unauthorized)
    reply(conn, 403, %{error: "machine_unavailable"})
  end

  defp bearer(%Plug.Conn{scheme: :https} = conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) == @bearer_bytes -> {:ok, token}
      _ -> {:error, :unauthorized}
    end
  end

  defp bearer(_), do: {:error, :unauthorized}

  defp reply(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
