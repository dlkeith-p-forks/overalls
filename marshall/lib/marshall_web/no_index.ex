defmodule MarshallWeb.NoIndex do
  @moduledoc "Standard X-Robots-Tag directive asking search engines not to index Marshall."
  @behaviour Plug
  import Plug.Conn

  @directive "noindex, nofollow, noarchive, nosnippet, noimageindex"

  @impl true
  @spec init(Plug.opts()) :: Plug.opts()
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] endpoint-no-index
  # Every browser-endpoint response, including static files, health probes and
  # early refusals, MUST carry the standard X-Robots-Tag noindex directive.
  @impl true
  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(conn, _options), do: put_resp_header(conn, "x-robots-tag", @directive)

  @doc "The directive also published as the robots meta tag in the root layout."
  @spec directive() :: String.t()
  def directive, do: @directive
end
