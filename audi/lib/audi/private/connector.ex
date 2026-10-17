defmodule Audi.Private.Connector do
  @moduledoc "UID-authenticated Lilly subscription to the binding of a transport-derived source address."
  @type purpose :: OverallsProtocol.PrivateServices.purpose()

  # @cc [owner:ghuntley,label:security] private-connector-subscription
  # subscribe/4 MUST authenticate Lilly as the configured UID by peer credentials
  # (the unprivileged service user in production, ADR-0182), send one
  # v3 request for the transport-derived source address, and accept only a
  # grant whose binding validates for the requested purpose. On success the
  # caller receives the still-open socket: Lilly revokes by sending the fixed
  # revocation frame or closing it. Every failure returns :unavailable.
  @spec subscribe(Path.t(), non_neg_integer(), :inet.ip_address(), purpose()) ::
          {:ok, map(), :gen_tcp.socket()} | {:error, :unavailable}
  def subscribe(path, uid, {_, _, _, _} = peer, purpose)
      when is_integer(uid) and purpose in [:services, :ssh_roster, :ssh_host_certificate] do
    with {:ok, socket} <-
           :gen_tcp.connect(
             {:local, path},
             0,
             [
               :binary,
               active: false,
               packet: 4,
               packet_size: 2048,
               send_timeout: 1000,
               send_timeout_close: true
             ],
             1000
           ) do
      request =
        OverallsProtocol.PrivateServices.watch_request(to_string(:inet.ntoa(peer)), purpose)

      with {:ok,
            [
              {:raw, 1, 17,
               <<_pid::native-signed-32, ^uid::native-unsigned-32, _gid::native-unsigned-32>>}
            ]} <- :inet.getopts(socket, [{:raw, 1, 17, 12}]),
           :ok <- :gen_tcp.send(socket, JSON.encode!(request)),
           {:ok, bytes} <- :gen_tcp.recv(socket, 0, 1000),
           {:ok, reply} <- JSON.decode(bytes),
           {:ok, binding} <- OverallsProtocol.PrivateServices.decode_grant(reply, purpose) do
        {:ok, binding, socket}
      else
        _ ->
          :gen_tcp.close(socket)
          {:error, :unavailable}
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  def subscribe(_, _, _, _), do: {:error, :unavailable}
end
