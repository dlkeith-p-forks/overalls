defmodule Audi.DNS.Replica do
  @moduledoc "Single-flight background refresh of a complete DNS publication replica."
  use GenServer
  alias Audi.Control.Client
  alias Audi.DNS.Directory
  require Audi.Events

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec automatic_work_enabled?(GenServer.server()) :: boolean()
  def automatic_work_enabled?(server) do
    GenServer.call(server, :automatic_work_enabled?, 1000)
  catch
    :exit, _ -> false
  end

  @impl true
  def handle_call(:automatic_work_enabled?, _, state), do: {:reply, not state.halted?, state}

  @impl true
  def init(options) do
    :logger.update_process_metadata(%{audi_private: true})
    client = Keyword.fetch!(options, :client)

    if match?(%Client{role: :dns}, client) do
      state = %{
        client: client,
        directory: Keyword.fetch!(options, :directory),
        zone: Keyword.fetch!(options, :zone),
        timer: make_ref(),
        halted?: false,
        health: nil
      }

      send(self(), {:refresh, state.timer})

      # Zone hints refresh at once; the one-second retry stays the backstop.
      if Process.whereis(Audi.Control.Hints),
        do: {:ok, _} = Registry.register(Audi.Control.Hints, "dns_snapshot", nil)

      {:ok, state}
    else
      {:stop, :invalid_replica_configuration}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] audi-dns-single-flight-refresh
  # Refresh MUST use the authenticated complete-snapshot transport with at most
  # one request in flight. It MUST publish atomically without extending any
  # deadline. Failure MUST NOT clear, refresh or recreate the old snapshot;
  # expired state remains unavailable. Retries wait one second after completion;
  # a dns_snapshot hint refreshes at once, coalescing queued hints into one read.
  # An explicit unsupported version MUST halt refreshes until restart without
  # discarding or extending the previously published snapshot's authority.
  # DNS queries MUST NOT trigger control requests, and OTP status MUST redact state.
  @impl true
  def handle_info({:refresh, timer}, %{timer: timer, halted?: false} = state) do
    result =
      case Client.dns_snapshot(state.client, state.zone) do
        {:ok, snapshot} ->
          Directory.publish(
            state.directory,
            snapshot.revision,
            snapshot.entries,
            snapshot.expires_at
          )

        {:error, :unsupported_version} ->
          :unsupported_version

        {:error, _} ->
          :error
      end

    health = if result == :ok, do: :available, else: :unavailable

    if health != state.health do
      case health do
        :available -> Audi.Events.emit("audi.dns_available", [])
        :unavailable -> Audi.Events.emit("audi.dns_unavailable", [])
      end
    end

    if result == :unsupported_version do
      Audi.Events.emit("audi.control_version_refused", owner: :dns_replica)
      {:noreply, %{state | timer: nil, health: health, halted?: true}}
    else
      next = make_ref()
      Process.send_after(self(), {:refresh, next}, 1000)
      {:noreply, %{state | timer: next, health: health}}
    end
  end

  # A hint refreshes now with the current timer reference; the pending timer
  # then carries a stale reference and is ignored, keeping one refresh in flight.
  # Queued hints are drained first so a burst costs one snapshot read.
  def handle_info({:control_hint, "dns_snapshot", _id}, %{halted?: false} = state) do
    drain_hints()
    handle_info({:refresh, state.timer}, state)
  end

  def handle_info(_, state), do: {:noreply, state}

  @spec drain_hints() :: :ok
  defp drain_hints do
    receive do
      {:control_hint, "dns_snapshot", _id} -> drain_hints()
    after
      0 -> :ok
    end
  end

  @impl true
  # @cc [owner:ghuntley,label:privacy] replica-status-redaction
  # Preserve OTP status keys so the runtime accepts redaction; remove payloads
  # from state, messages, reasons and debug logs before status/crash formatting.
  @spec format_status(map()) :: map()
  def format_status(status) do
    Map.new(status, fn
      {:log, _} -> {:log, []}
      {key, _} -> {key, :redacted}
    end)
  end
end
