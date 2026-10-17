defmodule Marshall.Test.WebSocketClient do
  @moduledoc """
  Test-only blocking facade over `OverallsProtocol.WebSocket.Connection`: a
  process owns the active-once connection and queues received frames, so a
  test can `recv/2` binary frames one at a time.
  """
  use GenServer

  alias OverallsProtocol.WebSocket.Connection

  @spec open(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(base_url, path, options) do
    case GenServer.start(__MODULE__, {base_url, path, options}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec send_binary(pid(), binary()) :: :ok | {:error, term()}
  def send_binary(client, bytes), do: GenServer.call(client, {:send, bytes})

  @spec recv(pid(), timeout()) :: {:ok, {:binary, binary()}} | {:error, :timeout | :closed}
  def recv(client, timeout), do: GenServer.call(client, {:recv, timeout}, timeout + 1_000)

  @spec close(pid()) :: :ok
  def close(client) do
    GenServer.stop(client)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({base_url, path, options}) do
    case Connection.open(base_url, path, Keyword.put_new(options, :limit, 262_158)) do
      {:ok, connection} ->
        state = %{connection: connection, frames: :queue.new(), waiter: nil, closed: false}
        {:ok, absorb(state, Connection.pending(connection))}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, bytes}, _from, state),
    do: {:reply, Connection.send_frame(state.connection, {:binary, bytes}), state}

  def handle_call({:recv, timeout}, from, state) do
    case :queue.out(state.frames) do
      {{:value, frame}, frames} ->
        {:reply, {:ok, frame}, %{state | frames: frames}}

      {:empty, _} when state.closed ->
        {:reply, {:error, :closed}, state}

      {:empty, _} ->
        timer = Process.send_after(self(), {:recv_timeout, from}, timeout)
        {:noreply, %{state | waiter: {from, timer}}}
    end
  end

  @impl true
  def handle_info({:recv_timeout, from}, %{waiter: {from, _timer}} = state) do
    GenServer.reply(from, {:error, :timeout})
    {:noreply, %{state | waiter: nil}}
  end

  def handle_info(message, state) do
    case Connection.stream(state.connection, message) do
      :unknown -> {:noreply, state}
      result -> {:noreply, absorb(state, result)}
    end
  end

  @impl true
  def terminate(_reason, state), do: Connection.close(state.connection)

  defp absorb(state, {:ok, connection, frames}) do
    binaries = for {:binary, bytes} <- frames, do: {:binary, bytes}
    closed = Enum.any?(frames, &match?({:close, _, _}, &1))

    deliver(%{
      state
      | connection: connection,
        frames: Enum.reduce(binaries, state.frames, &:queue.in/2),
        closed: state.closed or closed
    })
  end

  defp absorb(state, _closed_or_error), do: deliver(%{state | closed: true})

  defp deliver(%{waiter: {from, timer}} = state) do
    case :queue.out(state.frames) do
      {{:value, frame}, frames} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, frame})
        %{state | frames: frames, waiter: nil}

      {:empty, _} when state.closed ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:error, :closed})
        %{state | waiter: nil}

      {:empty, _} ->
        state
    end
  end

  defp deliver(state), do: state
end
