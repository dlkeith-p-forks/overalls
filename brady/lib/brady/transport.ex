defmodule Brady.Transport do
  @moduledoc "Passive bounded-time socket operations with closed errors."
  @type t :: {:tcp, :gen_tcp.socket()} | {:tls, :ssl.sslsocket()}

  @spec recv(t(), non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, :closed | :timeout | :transport}
  def recv(transport, length \\ 0, timeout \\ 15_000) do
    result =
      case transport do
        {:tcp, socket} -> :gen_tcp.recv(socket, length, timeout)
        {:tls, socket} -> :ssl.recv(socket, length, timeout)
      end

    case result do
      {:ok, data} when is_binary(data) -> {:ok, data}
      {:error, reason} when reason in [:closed, :timeout] -> {:error, reason}
      _ -> {:error, :transport}
    end
  end

  @spec send(t(), iodata()) :: :ok | {:error, :transport}
  def send(transport, bytes) do
    result =
      case transport do
        {:tcp, socket} -> :gen_tcp.send(socket, bytes)
        {:tls, socket} -> :ssl.send(socket, bytes)
      end

    if result == :ok, do: :ok, else: {:error, :transport}
  end

  @spec close(t()) :: :ok
  def close({:tcp, socket}), do: :gen_tcp.close(socket)

  def close({:tls, socket}) do
    :ssl.close(socket)
    :ok
  end
end
