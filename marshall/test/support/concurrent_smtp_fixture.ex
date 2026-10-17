defmodule Marshall.ConcurrentSMTPFixture do
  @moduledoc "Concurrent verified-TLS test relay with a first-DATA acknowledgment gate."
  use GenServer

  @type mode :: :implicit | :starttls
  @type identity :: %{message_id: binary(), text: binary(), html: binary(), token: binary()}
  @type state :: %{
          listener: :gen_tcp.socket(),
          supervisor: pid(),
          port: :inet.port_number(),
          count: non_neg_integer()
        }
  @type options :: [
          {:owner, pid()}
          | {:mode, mode()}
          | {:cert, String.t()}
          | {:key, String.t()}
          | {:first_reply, binary()}
        ]

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)
  @spec connections(pid()) :: non_neg_integer()
  def connections(server), do: GenServer.call(server, :connections)
  @spec release(pid()) :: :ok
  def release(server), do: GenServer.call(server, :release)

  @impl true
  @spec init(options()) :: {:ok, state()}
  def init(opts) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, supervisor} = Task.Supervisor.start_link()
    server = self()

    {:ok, _} =
      Task.Supervisor.start_child(supervisor, fn -> accept(server, supervisor, listener, opts) end)

    {:ok, %{listener: listener, supervisor: supervisor, port: port, count: 0}}
  end

  @impl true
  @spec handle_call(:port | :connections | :accepted | :release, GenServer.from(), state()) ::
          {:reply, non_neg_integer() | :ok, state()}
  def handle_call(:port, _, state), do: {:reply, state.port, state}
  def handle_call(:connections, _, state), do: {:reply, state.count, state}

  def handle_call(:accepted, _, state),
    do: {:reply, state.count + 1, %{state | count: state.count + 1}}

  def handle_call(:release, _, state) do
    Enum.each(Task.Supervisor.children(state.supervisor), &send(&1, :release))
    {:reply, :ok, state}
  end

  @impl true
  @spec terminate(term(), state()) :: :ok
  def terminate(_, state) do
    :gen_tcp.close(state.listener)
    Supervisor.stop(state.supervisor)
    :ok
  end

  # @cc [owner:ghuntley,label:verification;concurrency] smtp-independent-handlers
  # Acceptance MUST continue while earlier DATA awaits acknowledgment. Every
  # accepted socket MUST transfer to its own supervised handler before TLS;
  # serialized acceptance MUST NOT hide a duplicate-worker connection.
  @spec accept(pid(), pid(), :gen_tcp.socket(), options()) :: :ok
  defp accept(server, supervisor, listener, opts) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        number = GenServer.call(server, :accepted)

        {:ok, handler} =
          Task.Supervisor.start_child(supervisor, fn ->
            receive do
              {:socket, socket} -> session(socket, opts, number)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, {:socket, socket})
        send(Keyword.fetch!(opts, :owner), {:smtp_accepted, number, handler})
        accept(server, supervisor, listener, opts)

      {:error, :closed} ->
        :ok
    end
  end

  @spec session(:gen_tcp.socket(), options(), pos_integer()) :: :ok
  defp session(socket, opts, number) do
    case Keyword.fetch!(opts, :mode) do
      :implicit ->
        {:ok, tls} = upgrade(socket, opts)
        :ssl.send(tls, "220 localhost concurrent fixture\r\n")
        commands(:ssl, tls, opts, number, true)

      :starttls ->
        :inet.setopts(socket, packet: :line)
        :gen_tcp.send(socket, "220 localhost concurrent fixture\r\n")
        commands(:gen_tcp, socket, opts, number, false)
    end

    :ok
  end

  @spec upgrade(:gen_tcp.socket(), options()) :: {:ok, :ssl.sslsocket()} | {:error, term()}
  defp upgrade(socket, opts) do
    :inet.setopts(socket, packet: :raw)

    case :ssl.handshake(socket, [certfile: opts[:cert], keyfile: opts[:key], active: false], 5000) do
      {:ok, tls} ->
        :ssl.setopts(tls, packet: :line)
        {:ok, tls}

      error ->
        error
    end
  end

  @spec commands(
          :gen_tcp | :ssl,
          :gen_tcp.socket() | :ssl.sslsocket(),
          options(),
          pos_integer(),
          boolean()
        ) :: :ok
  defp commands(transport, socket, opts, number, encrypted?) do
    case transport.recv(socket, 0, 15_000) do
      {:ok, "EHLO " <> _} ->
        starttls = if encrypted?, do: "", else: "250-STARTTLS\r\n"
        transport.send(socket, "250-localhost\r\n" <> starttls <> "250 AUTH PLAIN\r\n")
        commands(transport, socket, opts, number, encrypted?)

      {:ok, "STARTTLS\r\n"} when not encrypted? ->
        transport.send(socket, "220 TLS\r\n")
        {:ok, tls} = upgrade(socket, opts)
        commands(:ssl, tls, opts, number, true)

      {:ok, "AUTH PLAIN " <> _} when encrypted? ->
        transport.send(socket, "235 Authenticated\r\n")
        commands(transport, socket, opts, number, encrypted?)

      {:ok, "MAIL FROM:" <> _} when encrypted? ->
        transport.send(socket, "250 Accepted\r\n")
        commands(transport, socket, opts, number, encrypted?)

      {:ok, "RCPT TO:" <> _} when encrypted? ->
        transport.send(socket, "250 Accepted\r\n")
        commands(transport, socket, opts, number, encrypted?)

      {:ok, "DATA\r\n"} when encrypted? ->
        transport.send(socket, "354 DATA\r\n")
        {:ok, bytes} = data(transport, socket, <<>>)
        owner = Keyword.fetch!(opts, :owner)
        send(owner, {:smtp_data, number, self(), identity(bytes)})

        if number == 1 do
          :ok = :ssl.setopts(socket, active: :once)

          case await_release(
                 socket,
                 owner,
                 number,
                 Keyword.get(opts, :first_reply, "250 Accepted\r\n")
               ) do
            :released -> commands(transport, socket, opts, number, encrypted?)
            :closed -> :ok
          end
        else
          transport.send(socket, "250 Accepted\r\n")
          commands(transport, socket, opts, number, encrypted?)
        end

      {:ok, "QUIT\r\n"} ->
        transport.send(socket, "221 Goodbye\r\n")
        transport.close(socket)
        :ok

      _ ->
        transport.close(socket)
        :ok
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] smtp-real-gated-closure
  # The first complete DATA MUST remain unacknowledged until explicit release
  # or actual client closure. A closure receipt MUST come from SSL, never from
  # a fixture-initiated close. MIME observations MUST contain only digests.
  @spec await_release(:ssl.sslsocket(), pid(), pos_integer(), binary()) :: :released | :closed
  defp await_release(socket, owner, number, reply) do
    receive do
      :release ->
        :ssl.setopts(socket, active: false)
        :ok = :ssl.send(socket, reply)
        send(owner, {:smtp_reply_sent, number})
        :released

      {:ssl_closed, ^socket} ->
        send(owner, {:smtp_closed, number})
        :closed

      {:ssl_error, ^socket, _} ->
        send(owner, {:smtp_unexpected_close, number})
        :closed
    after
      15_000 ->
        send(owner, {:smtp_gate_timeout, number})
        :ssl.close(socket)
        :closed
    end
  end

  @spec data(:gen_tcp | :ssl, :gen_tcp.socket() | :ssl.sslsocket(), binary()) ::
          {:ok, binary()} | :error
  defp data(transport, socket, bytes) when byte_size(bytes) <= 65_536 do
    case transport.recv(socket, 0, 5000) do
      {:ok, ".\r\n"} -> {:ok, bytes}
      {:ok, line} -> data(transport, socket, bytes <> line)
      _ -> :error
    end
  end

  defp data(_, _, _), do: :error

  @spec identity(binary()) :: identity() | :invalid
  defp identity(bytes) do
    {"multipart", "alternative", headers, _, parts} = :mimemail.decode(bytes, [])
    {_, message_id} = Enum.find(headers, fn {key, _} -> String.downcase(key) == "message-id" end)
    {"text", "plain", _, _, text} = Enum.find(parts, &match?({"text", "plain", _, _, _}, &1))
    {"text", "html", _, _, html} = Enum.find(parts, &match?({"text", "html", _, _, _}, &1))
    [_, token] = Regex.run(~r{/magic_link/([^\s]+)}, text)

    %{
      message_id: message_id,
      text: :crypto.hash(:sha256, text),
      html: :crypto.hash(:sha256, html),
      token: :crypto.hash(:sha256, token)
    }
  rescue
    _ -> :invalid
  end
end
