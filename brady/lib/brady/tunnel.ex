defmodule Brady.Tunnel do
  @moduledoc "Explicit-exception TCP relay with active-once backpressure and an idle deadline."
  @spec run(:gen_tcp.socket(), :gen_tcp.socket(), binary()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, :transport}
  def run(client, upstream, initial) do
    with :ok <- :gen_tcp.send(upstream, initial),
         :ok <- :inet.setopts(client, active: :once),
         :ok <- :inet.setopts(upstream, active: :once) do
      relay(client, upstream, byte_size(initial), 0)
    else
      _ -> {:error, :transport}
    end
  end

  defp relay(client, upstream, sent, received) do
    receive do
      {:tcp, ^client, bytes} ->
        with :ok <- :gen_tcp.send(upstream, bytes),
             :ok <- :inet.setopts(client, active: :once),
             do: relay(client, upstream, sent + byte_size(bytes), received),
             else: (_ -> {:error, :transport})

      {:tcp, ^upstream, bytes} ->
        with :ok <- :gen_tcp.send(client, bytes),
             :ok <- :inet.setopts(upstream, active: :once),
             do: relay(client, upstream, sent, received + byte_size(bytes)),
             else: (_ -> {:error, :transport})

      {:tcp_closed, socket} when socket == client or socket == upstream ->
        {:ok, sent, received}

      {:tcp_error, socket, _} when socket == client or socket == upstream ->
        {:error, :transport}
    after
      60_000 -> {:error, :transport}
    end
  end
end
