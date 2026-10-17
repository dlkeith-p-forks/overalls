defmodule Brady.Attribution do
  @moduledoc "Authenticated local attribution client; failures retain explicit unresolved identity."
  alias OverallsProtocol.EgressAttribution, as: Wire
  @path "/run/lilly-brady/attribution.sock"

  @spec lookup(String.t(), Wire.flow()) :: map()
  def lookup(host, flow), do: request(@path, host, flow, 0)

  # @cc [owner:ghuntley,label:security] brady-attribution-root-peer
  # Production lookup MUST require UID 0 via kernel peer credentials and an exact
  # configured host match. Closed tuple validation precedes sending. Timeouts,
  # wrong peers and malformed responses MUST return only unresolved host identity.
  # Callers of request/4 MUST supply trusted local path/UID, never guest fields.
  @spec request(Path.t(), String.t(), Wire.flow(), non_neg_integer()) :: map()
  def request(path, host, flow, uid) do
    unresolved = %{host_id: host, attribution: :unresolved}
    bytes = Wire.request(flow)

    with {:ok, ^flow} <- Wire.decode_request(bytes),
         {:ok, socket} <-
           :gen_tcp.connect(
             {:local, path},
             0,
             [
               :binary,
               active: false,
               packet: 2,
               packet_size: Wire.maximum(),
               send_timeout: 250,
               send_timeout_close: true
             ],
             250
           ) do
      try do
        with {:ok,
              [
                {:raw, 1, 17,
                 <<_pid::native-signed-32, ^uid::native-unsigned-32, _gid::native-unsigned-32>>}
              ]} <-
               :inet.getopts(socket, [{:raw, 1, 17, 12}]),
             :ok <- :gen_tcp.send(socket, bytes),
             {:ok, response} <- :gen_tcp.recv(socket, 0, 750),
             {:ok, %{host_id: ^host} = identity} <- Wire.decode_response(response),
             do: identity,
             else: (_ -> unresolved)
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> unresolved
    end
  rescue
    _ -> %{host_id: host, attribution: :unresolved}
  catch
    :exit, _ -> %{host_id: host, attribution: :unresolved}
  end
end
