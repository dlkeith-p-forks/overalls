defmodule Marshall.Enrico.AttemptStub do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  @impl true
  @spec init(Plug.opts()) :: Plug.opts()
  def init(state) when is_atom(state), do: state

  @impl true
  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "GET", path_info: ["v1", "repos", _, "attempts", _]} = conn, state)
      when is_atom(state) do
    {mode, poll} =
      Agent.get_and_update(state, fn %{mode: mode, polls: count} = current ->
        {{mode, count + 1}, %{current | polls: count + 1}}
      end)

    case {mode, poll} do
      {:resume, 1} -> respond(conn, 200, %{status: "running"})
      {:resume, 2} -> respond(conn, 503, %{error: "temporarily_unavailable"})
      {:missing, 1} -> respond(conn, 200, %{status: "missing"})
      _ -> respond(conn, 200, %{status: %{state: "succeeded", head: String.duplicate("a", 40)}})
    end
  end

  def call(%Plug.Conn{method: "POST"} = conn, state) when is_atom(state) do
    Agent.update(state, fn %{posts: count} = current -> %{current | posts: count + 1} end)
    respond(conn, 202, %{status: "running"})
  end

  def call(conn, _state), do: respond(conn, 404, %{error: "not_found"})

  @spec respond(Plug.Conn.t(), pos_integer(), map()) :: Plug.Conn.t()
  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
