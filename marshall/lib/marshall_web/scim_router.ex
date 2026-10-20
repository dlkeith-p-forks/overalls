defmodule MarshallWeb.ScimRouter do
  @moduledoc """
  SCIM 2.0 endpoint for Users (Marshall.Accounts) and Groups (Marshall.Teams).

  Each request runs inside a Ledger commit scope so team receipts and outcome
  events registered by SCIM actions are emitted only after their commits, and
  only for successful responses.
  """
  @behaviour Plug

  @ash_scim_opts [
    domains: [Marshall.Accounts, Marshall.Teams],
    auth: {Marshall.Scim.Auth, []},
    base_url: "/scim/v2"
  ]

  @impl Plug
  @spec init(keyword()) :: term()
  def init(extra), do: AshScim.Router.init(Keyword.merge(@ash_scim_opts, extra))

  # @cc [owner:ghuntley,label:observability] scim-request-commit-scope
  # SCIM outcome callbacks MUST run once after a successful (2xx/3xx) response
  # and MUST be discarded for refused or failed requests.
  @impl Plug
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, opts) do
    case Marshall.Compute.Ledger.commit_scope(fn ->
           conn = AshScim.Router.call(conn, opts)
           if is_integer(conn.status) and conn.status < 400, do: {:ok, conn}, else: {:error, conn}
         end) do
      {:ok, conn} -> Plug.Conn.halt(conn)
      {:error, conn} -> Plug.Conn.halt(conn)
    end
  end
end
