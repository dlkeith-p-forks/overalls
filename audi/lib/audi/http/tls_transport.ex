defmodule Audi.HTTP.TLSTransport do
  @moduledoc "Thousand Island TLS transport with a finite handshake deadline."
  @behaviour ThousandIsland.Transport

  # @cc [owner:ghuntley,label:security] audi-tls-handshake-deadline
  # TLS setup MUST finish or fail within five seconds even when a peer sends no
  # ClientHello. All other transport semantics remain the pinned SSL adapter's.
  @impl true
  def handshake(socket) do
    case :ssl.handshake(socket, 5000) do
      {:ok, socket, _} -> {:ok, socket}
      result -> result
    end
  end

  @impl true
  def upgrade(socket, options) do
    now = System.monotonic_time(:millisecond)
    {deadline, options} = Keyword.pop(options, :audi_deadline, now + 5000)
    timeout = min(5000, max(0, deadline - now))

    case :ssl.handshake(socket, options, timeout) do
      {:ok, socket, _} -> {:ok, socket}
      result -> result
    end
  end

  for {name, arity} <- ThousandIsland.Transport.behaviour_info(:callbacks),
      {name, arity} not in [{:handshake, 1}, {:upgrade, 2}] do
    arguments = Macro.generate_arguments(arity, __MODULE__)
    @impl true
    defdelegate unquote(name)(unquote_splicing(arguments)), to: ThousandIsland.Transports.SSL
  end
end
