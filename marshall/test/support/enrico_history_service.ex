defmodule Marshall.EnricoHistoryService do
  @moduledoc "Bounded HTTPS service double retaining independent per-attempt results."
  @behaviour Plug
  import Plug.Conn
  @type result :: String.t() | %{state: String.t(), head: String.t()}
  @type state :: %{
          next: result(),
          attempts: %{String.t() => result()},
          requests: non_neg_integer()
        }

  @impl true
  @spec init(Plug.opts()) :: Plug.opts()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    state = Keyword.fetch!(opts, :state)
    Agent.update(state, fn current -> %{current | requests: current.requests + 1} end)
    dispatch(conn, state)
  end

  @spec dispatch(Plug.Conn.t(), pid()) :: Plug.Conn.t()
  defp dispatch(
         %Plug.Conn{method: "POST", path_info: ["v1", "repos", _, "refresh"]} = conn,
         state
       ) do
    {:ok, bytes, conn} = read_body(conn)
    %{"attempt_id" => attempt} = JSON.decode!(bytes)
    true = OverallsProtocol.uuid?(attempt)

    Agent.update(state, fn current ->
      %{current | attempts: Map.put(current.attempts, attempt, current.next)}
    end)

    respond(conn, 202, %{status: "running"})
  end

  defp dispatch(
         %Plug.Conn{method: "GET", path_info: ["v1", "repos", _, "attempts", attempt]} = conn,
         state
       ) do
    status = Agent.get(state, &Map.get(&1.attempts, attempt, "missing"))
    respond(conn, 200, %{status: status})
  end

  defp dispatch(%Plug.Conn{method: "DELETE"} = conn, _), do: respond(conn, 200, %{removed: true})
  defp dispatch(conn, _), do: respond(conn, 404, %{error: "not_found"})

  @spec respond(Plug.Conn.t(), pos_integer(), map()) :: Plug.Conn.t()
  defp respond(conn, code, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(code, JSON.encode!(body))
end
