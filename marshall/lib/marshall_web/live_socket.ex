defmodule MarshallWeb.LiveSocket do
  @moduledoc "LiveView transport with payload-free diagnostics for multiplexed terminal traffic."
  use Phoenix.LiveView.Socket
  defoverridable init: 1

  @impl Phoenix.Socket
  def id(socket), do: super(socket)

  @impl Phoenix.Socket
  def connect(params, socket, info), do: super(params, socket, info)

  # @cc [owner:ghuntley,label:security] multiplexed-transport-privacy
  # init/1 MUST tag every LiveView transport before frames arrive, including
  # transports initially opened on pages other than the terminal. Navigation
  # can later multiplex guest bytes into that same process and its crash state.
  @impl Phoenix.Socket.Transport
  def init(state) do
    # The transport can carry a terminal page after navigation. Tag it before any
    # frames arrive; a transport crash must not print its message or buffer.
    Logger.metadata(marshall_terminal: true)
    super(state)
  end
end
