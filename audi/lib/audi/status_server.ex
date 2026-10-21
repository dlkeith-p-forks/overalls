defmodule Audi.StatusServer do
  @moduledoc "Private, bounded local readiness with no command input."
  use GenServer
  import Bitwise

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  # @cc [owner:ghuntley,label:security;recovery] audi-status-socket-boundary
  # The socket MUST live in a validated directory (`audi-status-private-directory`)
  # with the mode it permits (`audi-status-socket-mode`), refuse active sockets
  # and nonsocket entries, and expose only version/role/ready. Each accepted connection
  # receives a fresh bounded readiness check; no request bytes are interpreted.
  @impl true
  def init(options) do
    :logger.update_process_metadata(%{audi_private: true})
    path = Keyword.fetch!(options, :path)

    with true <- is_binary(path),
         :ok <- Audi.Config.status_socket(path),
         :ok <- remove_stale(path),
         {:ok, socket} <-
           :gen_tcp.listen(0, [
             :binary,
             ip: {:local, path},
             active: false,
             backlog: 8,
             send_timeout: 1000,
             send_timeout_close: true
           ]),
         {mode, group} = Audi.Config.status_socket_access(path),
         :ok <- if(group, do: File.chgrp(path, group), else: :ok),
         :ok <- File.chmod(path, mode) do
      client = Keyword.fetch!(options, :client)

      health =
        Keyword.get(options, :health, fn ->
          Audi.Health.ready?(
            client,
            Keyword.fetch!(options, :role),
            Keyword.get(options, :ports, [])
          )
        end)

      send(self(), :accept)
      {:ok, %{socket: socket, health: health, role: Keyword.fetch!(options, :role)}}
    else
      _ -> {:stop, :invalid_status_socket}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.socket, 250) do
      {:ok, client} ->
        :gen_tcp.send(
          client,
          JSON.encode!(%{version: 1, role: state.role, ready: ready(state.health)}) <> "\n"
        )

        :gen_tcp.close(client)

      {:error, :timeout} ->
        :ok

      {:error, _} ->
        exit(:status_listener_failed)
    end

    send(self(), :accept)
    {:noreply, state}
  end

  @impl true
  # @cc [owner:ghuntley,label:privacy] status-server-status-redaction
  # Preserve OTP status keys so the runtime accepts redaction; remove payloads
  # from state, messages, reasons and debug logs before status/crash formatting.
  @spec format_status(map()) :: map()
  def format_status(status) do
    Map.new(status, fn
      {:log, _} -> {:log, []}
      {key, _} -> {key, :redacted}
    end)
  end

  defp ready(health) do
    task = Task.async(fn -> safe_health(health) end)

    case Task.yield(task, 5000) || Task.shutdown(task, :brutal_kill) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp safe_health(health) do
    :logger.update_process_metadata(%{audi_private: true})
    health.() == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp remove_stale(path) do
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
