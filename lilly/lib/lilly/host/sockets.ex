defmodule Lilly.Host.Sockets do
  @moduledoc """
  Connections Lilly may not be able to open itself, because it runs as its
  service user (ADR-0182).

  Firecracker API and vsock sockets live in jails owned by per-VM uids, and
  ingress connections start inside VM network namespaces. Lilly always
  creates the socket it uses: lilly-hostd connects that socket on Lilly's
  behalf, or bridges it to a guest connection it dialled in the namespace,
  and `gen_tcp` wraps it (ADR-0184). The BEAM cannot close a descriptor it
  did not create, so hostd never sends one.
  """
  alias Lilly.Host.Hostd

  # @cc [owner:ghuntley,label:security] sockets-through-hostd
  # connect_local/3 MUST first connect directly with the caller's own rights
  # and, only when that is refused for lack of privilege (:eacces or :eperm),
  # create its own Unix stream socket, have lilly-hostd connect it
  # (Hostd.connect_unix/3) and wrap it with the caller's gen_tcp options.
  # connect_netns/3 MUST always create its own Unix stream socket and have
  # lilly-hostd bridge it to the guest (Hostd.bridge_netns_tcp/2): the
  # unprivileged BEAM cannot enter the namespace. Any other direct failure is
  # returned as is; a hostd refusal is {:error, :connect_failed}.
  @spec connect_local(Path.t(), list(), non_neg_integer()) ::
          {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect_local(path, options, timeout) do
    case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, options, timeout) do
      {:error, reason} when reason in [:eacces, :eperm] ->
        through_hostd(options, &Hostd.connect_unix(&1, path, bounded(timeout)))

      result ->
        result
    end
  end

  @spec connect_netns(Hostd.netns_tcp(), list(), non_neg_integer()) ::
          {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect_netns(request, options, timeout) do
    through_hostd(options, &Hostd.bridge_netns_tcp(&1, %{request | timeout: bounded(timeout)}))
  end

  defp bounded(timeout), do: timeout |> max(1) |> min(30_000)

  defp through_hostd(options, connect) do
    with {:ok, owned} <- :socket.open(:local, :stream, :default) do
      case connect.(owned) do
        :ok ->
          adopt(owned, options)

        error ->
          :socket.close(owned)
          error
      end
    end
  end

  # @cc [owner:ghuntley,label:security;concurrency] owned-socket-custody
  # adopt/2 MUST return a gen_tcp port over the descriptor of `owned`, a
  # socket this process created and owns, and MUST close `owned` exactly
  # once: at once when the port cannot be created, otherwise only after the
  # port is down (closed, its owner dead, wherever controlling_process moved
  # it). Nothing else may use `owned` meanwhile; gen_tcp never closes an
  # adopted descriptor itself.
  @doc false
  @spec adopt(:socket.socket(), list()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def adopt(owned, options) do
    with {:ok, fd} <- :socket.getopt(owned, {:otp, :fd}),
         {:ok, port} <- :gen_tcp.fdopen(fd, [{:inet_backend, :inet}, :local | options]) do
      custody = spawn(fn -> custody(owned) end)

      case :socket.setopt(owned, {:otp, :controlling_process}, custody) do
        :ok ->
          send(custody, {:watch, port})
          {:ok, port}

        error ->
          Process.exit(custody, :kill)
          :gen_tcp.close(port)
          :socket.close(owned)
          error
      end
    else
      error ->
        :socket.close(owned)
        error
    end
  end

  # Kept to one receive: should custody die while the port is live, the
  # descriptor number would be freed under the port.
  defp custody(owned) do
    receive do
      {:watch, port} ->
        monitor = :erlang.monitor(:port, port)

        receive do
          {:DOWN, ^monitor, :port, _, _} -> :socket.close(owned)
        end
    end
  end
end
