defmodule Susan.Replay do
  @moduledoc """
  The poke replay window (ADR-0224): a signed `issued_at` within ±5 minutes
  and a nonce never seen before for the same install identity.

  `check/5` is the pure model; the GenServer serialises it over node-local
  memory. A nonce is remembered for twice the window, after which its
  `issued_at` can no longer be fresh, so forgetting it cannot admit a replay.
  Durable at-most-once delivery across restarts is provided separately by
  delivery-id receipts (`Susan.Relay.DeliveryReceipt`).
  """
  use GenServer

  @window_seconds 300
  @retention_seconds 2 * @window_seconds

  @type seen :: %{optional({binary(), binary()}) => integer()}
  @type refusal :: :stale | :replayed

  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  # @cc [owner:ghuntley,label:security] susan-replay-window
  # A poke MUST be refused when issued_at is more than 300 seconds from Susan's
  # clock or when its (install, nonce) pair was already admitted within the
  # retention period. A refused poke MUST NOT record its nonce. Forgetting a
  # nonce MUST happen only after its issued_at can no longer be fresh.
  @spec check(seen(), binary(), binary(), integer(), integer()) ::
          {:ok, seen()} | {:error, refusal(), seen()}
  def check(seen, install, nonce, issued_at, now)
      when is_map(seen) and is_binary(install) and is_binary(nonce) and is_integer(issued_at) and
             is_integer(now) do
    cond do
      abs(now - issued_at) > @window_seconds -> {:error, :stale, seen}
      Map.get(seen, {install, nonce}, now - 1) >= now -> {:error, :replayed, seen}
      true -> {:ok, Map.put(seen, {install, nonce}, now + @retention_seconds)}
    end
  end

  @spec forget(seen(), integer()) :: seen()
  def forget(seen, now), do: Map.reject(seen, fn {_key, expires} -> expires < now end)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options),
    do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(options, :name, __MODULE__))

  @spec claim(binary(), binary(), integer(), integer(), GenServer.server()) ::
          :ok | {:error, refusal()}
  def claim(install, nonce, issued_at, now \\ System.os_time(:second), server \\ __MODULE__),
    do: GenServer.call(server, {:claim, install, nonce, issued_at, now})

  @impl true
  def init(seen) do
    Process.send_after(self(), :forget, 30_000)
    {:ok, seen}
  end

  @impl true
  def handle_call({:claim, install, nonce, issued_at, now}, _from, seen) do
    case check(seen, install, nonce, issued_at, now) do
      {:ok, seen} -> {:reply, :ok, seen}
      {:error, reason, seen} -> {:reply, {:error, reason}, seen}
    end
  end

  @impl true
  def handle_info(:forget, seen) do
    Process.send_after(self(), :forget, 30_000)
    {:noreply, forget(seen, System.os_time(:second))}
  end
end
