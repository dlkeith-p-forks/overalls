defmodule Lilly.Private.Readiness do
  @moduledoc "Require private service authority and TLS readiness before new guest execution."
  @spec ready?(Lilly.Network.Config.t()) :: boolean()
  def ready?(%{private_services: false}), do: true

  def ready?(%{host_id: host}) do
    with {:ok,
          %{
            status: 200,
            body: %{"version" => 1, "role" => "ziggy", "ready" => true, "host_id" => ^host}
          }} <-
           Req.get("http://ziggy/health/ready",
             unix_socket: "/run/ziggy/proxy.sock",
             retry: false,
             redirect: false,
             receive_timeout: 2000
           ),
         {:ok, socket} <-
           :gen_tcp.connect(
             {:local, "/run/audi-private/status.sock"},
             0,
             [:binary, active: false, packet: :line, packet_size: 4096],
             1000
           ) do
      try do
        with {:ok, bytes} <- :gen_tcp.recv(socket, 0, 2000),
             {:ok, %{"version" => 1, "role" => "private", "ready" => true}} <- JSON.decode(bytes),
             do: true,
             else: (_ -> false)
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> false
    end
  rescue
    _ -> false
  end
end
