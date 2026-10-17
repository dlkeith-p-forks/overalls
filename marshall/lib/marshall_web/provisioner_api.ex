defmodule MarshallWeb.ProvisionerAPI do
  @moduledoc """
  Lilly's terminal stream upgrade, isolated from browser sessions.

  Control requests run on the control WebSocket (ADR-0142); every other
  provisioner path falls through to the fleet listener's uncached 404.
  """
  @behaviour Plug
  import Plug.Conn
  alias Marshall.Compute.ProvisionerControl

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] bounded-provisioner-request
  # call/2 MUST require secure transport and a single Lilly authorization
  # header before upgrading; control request bodies are bounded by the control
  # socket's frame limits (ADR-0142). The v4 terminal stream is a WebSocket
  # upgrade bound to the same authenticated current execution session;
  # upgrades never read a body.
  @impl true
  def call(
        %Plug.Conn{method: "GET", path_info: ["api", "provisioners", "v4", "stream"]} = conn,
        _options
      ) do
    with :ok <- secure_transport(conn),
         ["Lilly " <> token] <- get_req_header(conn, "authorization"),
         true <- byte_size(token) == 80,
         {:ok, binding} <- ProvisionerControl.terminal_stream_identity(token) do
      WebSockAdapter.upgrade(
        conn,
        Marshall.Terminal.HostStream,
        {binding.host_id, binding.session_id, binding.epoch},
        timeout: :infinity,
        max_frame_size: 262_158,
        compress: false
      )
      |> halt()
    else
      _ -> conn |> put_status(404) |> send_resp(404, "") |> halt()
    end
  end

  def call(conn, _), do: conn

  # @cc [owner:ghuntley,label:security] provisioner-transport-no-header-trust
  # secure_transport/1 MUST require actual HTTPS except explicitly enabled
  # loopback development/test traffic. Forwarded headers MUST NOT convert an
  # unencrypted remote connection into authenticated transport.
  defp secure_transport(%{scheme: :https}), do: :ok

  defp secure_transport(%{remote_ip: ip}) do
    if ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] and
         Application.get_env(:marshall, :provisioner_allow_insecure_loopback, false),
       do: :ok,
       else: {:error, :https_required}
  end
end
