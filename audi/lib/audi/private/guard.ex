defmodule Audi.Private.Guard do
  @moduledoc "Event-driven local execution fence for a private frontend request."
  require Audi.Events

  @doc "Hands the subscription socket to a guard that fences the calling request."
  @spec start(:gen_tcp.socket(), map()) :: pid()
  def start(socket, binding) do
    owner = self()
    guard = spawn_link(fn -> wait(owner, binding) end)

    case :gen_tcp.controlling_process(socket, guard) do
      :ok -> send(guard, {:socket, socket})
      _ -> Process.exit(owner, :kill)
    end

    guard
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    send(pid, :stop)
    :ok
  end

  # @cc [owner:ghuntley,label:security] private-stream-local-fence
  # Loss or change of Lilly's current binding MUST close the guest request:
  # any frame from Lilly (the revocation), the subscription closing or erroring
  # fences it at once. There is no polling and no time window; Lilly re-checks
  # its own proof deadlines. Finishing the request closes the subscription, and
  # an existing request can never transfer to a replacement execution.
  defp wait(owner, binding) do
    ref = Process.monitor(owner)

    receive do
      {:socket, socket} ->
        :ok = :inet.setopts(socket, active: :once)
        watch(owner, ref, socket, binding)

      :stop ->
        :ok
    end
  end

  defp watch(owner, ref, socket, binding) do
    receive do
      :stop ->
        :gen_tcp.close(socket)

      {:DOWN, ^ref, :process, ^owner, _} ->
        :gen_tcp.close(socket)

      {tag, ^socket, _} when tag in [:tcp, :tcp_error] ->
        fence(owner, socket, binding)

      {:tcp_closed, ^socket} ->
        fence(owner, socket, binding)
    end
  end

  defp fence(owner, socket, binding) do
    :gen_tcp.close(socket)

    Audi.Events.emit("audi.private_request_fenced",
      vm_id: binding["vm_id"],
      host_id: binding["host_id"],
      placement_id: binding["placement_id"],
      reason: :binding_lost
    )

    Process.exit(owner, :kill)
  end
end
