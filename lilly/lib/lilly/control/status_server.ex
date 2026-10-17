defmodule Lilly.Control.StatusServer do
  @moduledoc "Private, bounded local deployment readiness; no remote execution interface."
  use GenServer
  import Bitwise
  alias Lilly.Host.PrivateFiles

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  # @cc [owner:ghuntley,label:security] status-socket-private-and-bounded
  # The socket MUST live in an owner-only directory, refuse existing nonsocket
  # paths, emit only the selected fixed readiness or numeric terminal-health
  # projection and bound each client's
  # work. It MUST NOT accept commands or disclose credentials or terminal data.
  @impl true
  def init(options) do
    path = Keyword.fetch!(options, :path)

    with :ok <- PrivateFiles.directory(Path.dirname(path)),
         :ok <- remove_socket(path),
         {:ok, socket} <-
           :gen_tcp.listen(0, [
             :binary,
             ip: {:local, path},
             active: false,
             backlog: 8,
             send_timeout: 1000,
             send_timeout_close: true
           ]),
         :ok <- File.chmod(path, 0o600) do
      send(self(), :accept)

      {:ok,
       %{
         socket: socket,
         runtime: Keyword.get(options, :runtime, Lilly.Control.Runtime),
         kind: Keyword.get(options, :kind, :readiness)
       }}
    else
      _ -> {:stop, :invalid_status_socket}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.socket, 250) do
      {:ok, client} ->
        payload = JSON.encode!(snapshot(state.runtime, state.kind))
        if byte_size(payload) <= 131_072, do: :gen_tcp.send(client, payload <> "\n")
        :gen_tcp.close(client)

      {:error, :timeout} ->
        :ok

      {:error, _} ->
        exit(:status_listener_failed)
    end

    send(self(), :accept)
    {:noreply, state}
  end

  defp snapshot(runtime, :terminal_metrics) do
    with %{host_id: host, terminal_ready: ready} <- GenServer.call(runtime, :status, 1000) do
      metrics = Lilly.Terminal.Metrics.snapshot(host)

      %{
        version: 1,
        host_id: host,
        gauges: Map.put(metrics.gauges, :terminal_stream_ready, if(ready, do: 1, else: 0)),
        counters: metrics.counters,
        vms: metrics.vms
      }
    end
  catch
    :exit, _ -> %{version: 1, unavailable: true}
  end

  defp snapshot(runtime, :readiness) do
    try do
      runtime
      |> GenServer.call(:status, 1000)
      |> Map.take([:ready, :phase, :protocol_version, :terminal_ready])
      |> Map.put(:version, 1)
    catch
      :exit, _ -> %{version: 1, ready: false, phase: :unavailable}
    end
  end

  @impl true
  def terminate(reason, state) do
    Lilly.SupervisedStop.emit(:status, reason)
    :gen_tcp.close(state.socket)
    :ok
  end

  defp remove_socket(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :other, mode: mode}} when band(mode, 0o170000) == 0o140000 ->
        case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 250) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            {:error, :socket_in_use}

          {:error, :econnrefused} ->
            File.rm(path)

          _ ->
            {:error, :unsafe_socket_path}
        end

      _ ->
        {:error, :unsafe_socket_path}
    end
  end
end
