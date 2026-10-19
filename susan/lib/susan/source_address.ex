defmodule Susan.SourceAddress do
  @moduledoc """
  Source-address handling without IP logging (ADR-0224).

  The peer address is reduced immediately to an HMAC-SHA256 digest under a
  random salt that exists only in memory and is replaced every UTC day. The
  digest keys the per-source rate bucket; neither the address nor the digest
  is logged, stored or returned. A forwarded address is believed only from a
  configured trusted proxy.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(options, :name, __MODULE__))

  # @cc [owner:ghuntley,label:privacy] susan-source-address-digest
  # A source address MUST be reduced to a daily-salted HMAC before any other
  # use; the salt MUST live only in memory and change every UTC day. Neither
  # the address nor its digest may be logged, persisted or returned.
  @spec digest(:inet.ip_address()) :: binary()
  def digest(address) when is_tuple(address) do
    salt = GenServer.call(__MODULE__, :salt)
    :crypto.mac(:hmac, :sha256, salt, :erlang.term_to_binary(address))
  end

  @doc "The client address: the last X-Forwarded-For hop when the peer is a trusted proxy."
  @spec client(:inet.ip_address(), [String.t()], [:inet.ip_address()]) :: :inet.ip_address()
  def client(peer, forwarded, trusted) do
    with true <- peer in trusted,
         [header | _] <- Enum.reverse(forwarded),
         last when is_binary(last) <- header |> String.split(",") |> List.last(),
         {:ok, address} <- :inet.parse_strict_address(String.to_charlist(String.trim(last))) do
      address
    else
      _ -> peer
    end
  end

  @impl true
  def init(:ok), do: {:ok, {Date.utc_today(), :crypto.strong_rand_bytes(32)}}

  @impl true
  def handle_call(:salt, _from, {day, salt} = state) do
    today = Date.utc_today()

    if today == day do
      {:reply, salt, state}
    else
      fresh = :crypto.strong_rand_bytes(32)
      {:reply, fresh, {today, fresh}}
    end
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)
end
