defmodule Marshall.SMTPFixture do
  @moduledoc false
  use GenServer

  @type transport :: :gen_tcp | :ssl
  @type socket :: :gen_tcp.socket() | :ssl.sslsocket()
  @type state :: %{listener: :gen_tcp.socket(), port: :inet.port_number()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @spec port(pid()) :: :inet.port_number()
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, _} = Task.start_link(fn -> accept(listener, opts) end)
    {:ok, %{listener: listener, port: port}}
  end

  @impl true
  @spec handle_call(:port, GenServer.from(), state()) :: {:reply, :inet.port_number(), state()}
  def handle_call(:port, _, state), do: {:reply, state.port, state}
  @impl true
  @spec terminate(term(), state()) :: :ok
  def terminate(_, state), do: :gen_tcp.close(state.listener)

  @spec accept(:gen_tcp.socket(), keyword()) :: :ok
  defp accept(listener, opts) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        send(opts[:owner], {:smtp_connection, self()})

        case Keyword.fetch!(opts, :mode) do
          :implicit ->
            case upgrade(socket, opts) do
              {:ok, tls} -> session(:ssl, tls, opts, true)
              _ -> :gen_tcp.close(socket)
            end

          _ ->
            :inet.setopts(socket, packet: :line)
            session(:gen_tcp, socket, opts, false)
        end

        accept(listener, opts)

      {:error, :closed} ->
        :ok
    end
  end

  @spec upgrade(:gen_tcp.socket(), keyword()) :: {:ok, :ssl.sslsocket()} | {:error, term()}
  defp upgrade(socket, opts) do
    :inet.setopts(socket, packet: :raw)

    case :ssl.handshake(socket, [certfile: opts[:cert], keyfile: opts[:key], active: false], 5000) do
      {:ok, tls} ->
        :ssl.setopts(tls, packet: :line)
        {:ok, tls}

      other ->
        other
    end
  end

  @spec session(transport(), socket(), keyword(), boolean()) :: :ok
  defp session(transport, socket, opts, encrypted?) do
    if opts[:stall] do
      send(opts[:owner], :smtp_stalled)

      case transport.recv(socket, 0, 15_000) do
        {:error, :closed} -> send(opts[:owner], :smtp_closed)
        _ -> :ok
      end
    else
      transport.send(socket, "220 localhost test SMTP\r\n")
      commands(transport, socket, opts, encrypted?)
    end

    _ = transport.close(socket)
    :ok
  end

  @spec commands(transport(), socket(), keyword(), boolean()) :: :ok
  defp commands(transport, socket, opts, encrypted?) do
    case transport.recv(socket, 0, 5000) do
      {:ok, "EHLO " <> _} ->
        starttls =
          if opts[:mode] == :starttls and not encrypted?, do: "250-STARTTLS\r\n", else: ""

        transport.send(socket, "250-localhost\r\n" <> starttls <> "250 AUTH PLAIN\r\n")
        commands(transport, socket, opts, encrypted?)

      {:ok, "STARTTLS\r\n"} ->
        transport.send(socket, "220 Ready for TLS\r\n")

        case upgrade(socket, opts) do
          {:ok, tls} -> commands(:ssl, tls, opts, true)
          _ -> :ok
        end

      {:ok, "AUTH PLAIN " <> _} ->
        send(opts[:owner], {:smtp_auth, encrypted?})
        transport.send(socket, "235 Authenticated\r\n")
        commands(transport, socket, opts, encrypted?)

      {:ok, "MAIL FROM:" <> _} ->
        transport.send(socket, "250 Sender accepted\r\n")
        commands(transport, socket, opts, encrypted?)

      {:ok, "RCPT TO:" <> _} ->
        transport.send(socket, "250 Recipient accepted\r\n")
        commands(transport, socket, opts, encrypted?)

      {:ok, "DATA\r\n"} ->
        transport.send(socket, "354 End with dot\r\n")

        case data(transport, socket, <<>>) do
          {:ok, bytes} ->
            send(opts[:owner], {:smtp_message, bytes})

            if opts[:stall_after_data] do
              await_owner_close(transport, socket, opts[:owner])
            else
              transport.send(socket, Keyword.get(opts, :reply, "250 message accepted\r\n"))
              commands(transport, socket, opts, encrypted?)
            end

          _ ->
            :ok
        end

      {:ok, "QUIT\r\n"} ->
        transport.send(socket, "221 Goodbye\r\n")
        :ok

      _ ->
        :ok
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] smtp-accepted-unobserved-close
  # A selected post-DATA stall MUST retain the complete received message without
  # acknowledging it. Closure evidence MUST come from the real transport after
  # the client owner terminates, never from a fixture-initiated close.
  @spec await_owner_close(transport(), socket(), pid()) :: :ok
  defp await_owner_close(transport, socket, owner) do
    send(owner, {:smtp_data_stalled, self()})

    case transport.recv(socket, 0, 15_000) do
      {:error, :closed} -> send(owner, {:smtp_data_closed, self()})
      _ -> send(owner, {:smtp_data_not_closed, self()})
    end

    :ok
  end

  @spec data(transport(), socket(), binary()) :: {:ok, binary()} | :error
  defp data(transport, socket, bytes) when byte_size(bytes) <= 65_536 do
    case transport.recv(socket, 0, 5000) do
      {:ok, ".\r\n"} -> {:ok, bytes}
      {:ok, line} -> data(transport, socket, bytes <> line)
      _ -> :error
    end
  end

  defp data(_, _, _), do: :error
end
