defmodule Audi.Connector do
  @moduledoc "Linux Unix-socket client for Lilly's restricted local connector."
  alias OverallsProtocol.IngressConnect
  require Audi.Events

  # @cc [owner:ghuntley,label:security] audi-connector-authenticated-local-peer
  # open/2 MUST use only the operator-configured absolute Unix socket path, verify
  # its connected peer UID before sending the binding, and complete a bounded
  # handshake before returning a passive raw socket owned by the caller.
  # Every failed handshake MUST close the socket and return a fixed error.
  @spec open(map(), map()) :: {:ok, :gen_tcp.socket()} | {:error, :connector_unavailable}
  def open(%{path: path, uid: uid}, binding)
      when is_binary(path) and is_integer(uid) and uid in 0..4_294_967_294 do
    with true <-
           byte_size(path) in 1..107 and Path.type(path) == :absolute and
             Path.expand(path) == path and not String.contains?(path, <<0>>),
         {:ok, message} <- IngressConnect.encode(binding),
         {:ok, socket} <-
           :gen_tcp.connect(
             {:local, path},
             0,
             [
               :binary,
               active: false,
               packet: 4,
               packet_size: IngressConnect.maximum(),
               send_timeout: 1000,
               send_timeout_close: true
             ],
             1000
           ) do
      handshake(socket, uid, message, if(binding.service == :editor, do: 22_000, else: 1000))
    else
      _ ->
        Audi.Events.emit("audi.connector_failed", reason: :connector_unavailable)
        {:error, :connector_unavailable}
    end
  end

  def open(_, _), do: {:error, :connector_unavailable}

  defp handshake(socket, uid, message, timeout) do
    result =
      with {:ok,
            [
              {:raw, 1, 17,
               <<_pid::native-signed-32, ^uid::native-unsigned-32, _gid::native-unsigned-32>>}
            ]} <-
             :inet.getopts(socket, [{:raw, 1, 17, 12}]),
           :ok <- :gen_tcp.send(socket, message),
           {:ok, response} <- :gen_tcp.recv(socket, 0, timeout),
           true <- IngressConnect.ready?(response),
           :ok <- :inet.setopts(socket, packet: 0, packet_size: 0) do
        {:ok, socket}
      else
        _ -> {:error, :connector_unavailable}
      end

    case result do
      {:error, :connector_unavailable} = failure ->
        :gen_tcp.close(socket)
        Audi.Events.emit("audi.connector_failed", reason: :connector_unavailable)
        failure

      _ ->
        result
    end
  end
end
