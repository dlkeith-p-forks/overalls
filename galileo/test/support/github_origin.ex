defmodule Galileo.GitHubOrigin do
  @moduledoc false
  @behaviour Plug
  @impl true
  @spec init({pid(), (Plug.Conn.t() -> Plug.Conn.t())}) ::
          {pid(), (Plug.Conn.t() -> Plug.Conn.t())}
  def init(options), do: options
  @impl true
  @spec call(Plug.Conn.t(), {pid(), (Plug.Conn.t() -> Plug.Conn.t())}) :: Plug.Conn.t()
  def call(conn, {owner, responder}) do
    send(owner, {:origin_request, conn.method, conn.request_path, conn.req_headers})
    responder.(conn)
  end
end
