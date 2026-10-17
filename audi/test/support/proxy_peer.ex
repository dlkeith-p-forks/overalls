defmodule Audi.Test.ProxyPeer do
  @moduledoc false
  use ThousandIsland.Handler
  @impl true
  def handle_connection(socket, {owner, expected} = state) do
    send(owner, {:proxy_peer, Audi.Inception.Peer.read(socket, expected)})
    {:close, state}
  end
end
