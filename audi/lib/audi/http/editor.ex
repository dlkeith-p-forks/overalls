defmodule Audi.HTTP.Editor do
  @moduledoc "Personal browser editor admission over the shared bounded HTTP/WebSocket relay."
  import Plug.Conn
  alias Audi.Control.Client
  alias Audi.HTTP.{Authority, EditorBrowser, Proxy, WebSocketUpgrade}
  require Audi.Events

  # @cc [owner:ghuntley,label:security] audi-editor-origin-before-authority
  # WebSocket and unsafe requests MUST carry exactly the editor's canonical
  # Origin before authority lookup or guest connection. Sibling origins, null,
  # duplicate and absent origins MUST be refused. A malformed reserved editor
  # hostname MUST NOT fall back to ordinary application authority.
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, options) do
    conn = put_resp_header(conn, "x-frame-options", "DENY")

    with {:ok, label} <- EditorBrowser.target(conn.host, options[:zone]),
         true <- origin_allowed?(conn),
         {:ok, grant} <- Client.open_editor(options[:client], label, credential(conn)),
         true <- grant.binding.editor_origin == origin(conn),
         {:ok, renewal} <- Authority.start(options[:client], grant) do
      conn = worker_frame_header(conn, grant.binding)
      admitted(grant.binding)

      result =
        if WebSocketUpgrade.requested?(conn),
          do: WebSocketUpgrade.call(conn, options[:connector], grant, renewal, nil),
          else: Proxy.forward(conn, options[:connector], grant, nil)

      unless result.state == :upgraded do
        Authority.finish(renewal)
        closed(grant.binding)
      end

      result
    else
      {:error, :authentication_required} ->
        denied(:authentication_required)
        EditorBrowser.start(conn, options[:client], options[:zone], options[:browser_origin])

      {:error, :forbidden} ->
        denied(:forbidden)
        send_resp(conn, 403, "Access denied\n")

      false ->
        denied(:origin_mismatch)
        send_resp(conn, 403, "Access denied\n")

      _ ->
        denied(:unavailable)
        send_resp(conn, 503, "Service unavailable\n")
    end
  end

  @spec origin_allowed?(Plug.Conn.t()) :: boolean()
  def origin_allowed?(conn) do
    if WebSocketUpgrade.requested?(conn) or conn.method not in ["GET", "HEAD", "OPTIONS"],
      do: get_req_header(conn, "origin") == [origin(conn)],
      else: true
  end

  @spec origin(Plug.Conn.t()) :: binary()
  def origin(conn),
    do: "https://" <> conn.host <> if(conn.port == 443, do: "", else: ":#{conn.port}")

  # @cc [owner:ghuntley,label:security] audi-editor-worker-framing
  # Only an admitted GET/HEAD for the exact packaged browser extension-worker
  # iframe at the granted source commit may use SAMEORIGIN. Every other editor
  # response MUST retain DENY; sibling origins cannot embed the worker iframe.
  # Guest framing headers MUST NOT replace or duplicate this platform policy.
  @spec worker_frame_header(Plug.Conn.t(), OverallsProtocol.EditorConnect.binding()) ::
          Plug.Conn.t()
  defp worker_frame_header(conn, binding) do
    path =
      "/stable-" <>
        binding.editor_commit <>
        "/static/out/vs/workbench/services/extensions/worker/webWorkerExtensionHostIframe.html"

    framing =
      if conn.method in ["GET", "HEAD"] and conn.request_path == path,
        do: "SAMEORIGIN",
        else: "DENY"

    conn
    |> enforce_frame_header(framing)
    |> register_before_send(&enforce_frame_header(&1, framing))
  end

  @spec enforce_frame_header(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp enforce_frame_header(conn, framing) do
    headers = Enum.reject(conn.resp_headers, fn {name, _} -> name == "x-frame-options" end)
    put_resp_header(%{conn | resp_headers: headers}, "x-frame-options", framing)
  end

  defp credential(conn) do
    case EditorBrowser.credential(conn) do
      {:ok, token} -> token
      :error -> nil
    end
  end

  defp denied(reason), do: Audi.Events.emit("audi.editor_denied", reason: reason)

  defp admitted(binding) do
    Audi.Events.emit("audi.editor_admitted",
      host_id: binding.host_id,
      vm_id: binding.vm_id,
      placement_id: binding.placement_id,
      session_id: binding.session_id,
      guest_account_id: binding.guest_account_id,
      user_id: binding.user_id,
      execution_epoch: binding.execution_epoch,
      generation: binding.generation
    )
  end

  @doc false
  @spec closed(OverallsProtocol.EditorConnect.binding()) :: :ok
  def closed(binding) do
    Audi.Events.emit("audi.editor_closed",
      host_id: binding.host_id,
      vm_id: binding.vm_id,
      placement_id: binding.placement_id,
      session_id: binding.session_id,
      guest_account_id: binding.guest_account_id,
      user_id: binding.user_id,
      execution_epoch: binding.execution_epoch,
      generation: binding.generation
    )
  end
end
