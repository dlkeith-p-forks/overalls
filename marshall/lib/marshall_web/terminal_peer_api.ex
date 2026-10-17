defmodule MarshallWeb.TerminalPeerAPI do
  @moduledoc "Purpose-bound frontend peer upgrade on the private fleet listener."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] terminal-peer-proof-bound-to-incarnation
  # Upgrade MUST require HTTPS and a signed fifteen-second peer proof matching
  # the current unexpired stream location and local incarnation. Browser login
  # tokens and Lilly credentials MUST NOT authorize peer forwarding.
  @impl true
  def call(
        %Plug.Conn{
          scheme: :https,
          method: "GET",
          path_info: ["api", "terminal-peer", "v1", "stream"]
        } = conn,
        _
      ) do
    with ["TerminalPeer " <> proof] <- get_req_header(conn, "authorization"),
         true <- byte_size(proof) <= 2048,
         {:ok, {host_id, nonce}} <-
           Phoenix.Token.verify(MarshallWeb.Endpoint, "terminal-peer-v1", proof, max_age: 15),
         true <- OverallsProtocol.uuid?(host_id) and OverallsProtocol.uuid?(nonce),
         {:ok, %{nonce: ^nonce}} <- Marshall.Terminal.Directory.lookup(host_id),
         {:ok, _} <- Marshall.Terminal.Relay.local_stream(host_id, nonce) do
      conn
      |> WebSockAdapter.upgrade(Marshall.Terminal.PeerSocket, {host_id, nonce},
        timeout: :infinity,
        max_frame_size: 262_158,
        compress: false
      )
      |> halt()
    else
      _ -> conn |> send_resp(404, "") |> halt()
    end
  end

  def call(conn, _), do: conn
end
