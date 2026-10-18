defmodule Galileo.GitHubRaisingBodyAdapter do
  @moduledoc false
  @behaviour Plug.Conn.Adapter
  alias Plug.Adapters.Test.Conn, as: TestAdapter
  @impl true
  defdelegate send_resp(payload, status, headers, body), to: TestAdapter
  @impl true
  defdelegate send_file(payload, status, headers, path, offset, length), to: TestAdapter
  @impl true
  defdelegate send_chunked(payload, status, headers), to: TestAdapter
  @impl true
  defdelegate chunk(payload, body), to: TestAdapter
  @impl true
  defdelegate inform(payload, status, headers), to: TestAdapter
  @impl true
  defdelegate upgrade(payload, protocol, options), to: TestAdapter
  @impl true
  defdelegate push(payload, path, headers), to: TestAdapter
  @impl true
  defdelegate get_peer_data(payload), to: TestAdapter
  @impl true
  defdelegate get_sock_data(payload), to: TestAdapter
  @impl true
  defdelegate get_ssl_data(payload), to: TestAdapter
  @impl true
  defdelegate get_http_protocol(payload), to: TestAdapter
  @impl true
  @spec read_req_body(term(), keyword()) :: no_return()
  def read_req_body(_payload, _options), do: raise("request body must remain unread")
end
