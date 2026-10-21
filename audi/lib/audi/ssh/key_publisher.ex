defmodule Audi.SSH.KeyPublisher do
  @moduledoc "Bounded, idempotent public host-key registration over the verified control channel."
  use GenServer
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

    with {:ok, key} <- Audi.SSH.HostKey.public(Keyword.fetch!(options, :host_key_dir)) do
      send(self(), :publish)
      {:ok, %{client: Keyword.fetch!(options, :client), key: key, last: nil, halted?: false}}
    else
      _ -> {:stop, :invalid_host_key}
    end
  end

  # @cc [owner:ghuntley,label:security] audi-host-key-bounded-publication
  # At most one bounded verified-HTTPS publication may run at a time. Errors
  # MUST neither replace keys nor grant authority. Retries MUST wait 30 seconds
  # after completion, never accumulate work during an outage.
  # Explicit unsupported version MUST halt automatic publication until restart;
  # local host-key bytes MUST remain unchanged.
  @impl true
  def handle_info(:publish, %{halted?: false} = state) do
    outcome = Audi.Control.Client.publish_host_key(state.client, state.key)
    state = report(outcome, state)

    if outcome == {:error, :unsupported_version} do
      Audi.Events.emit("audi.control_version_refused", owner: :ssh_key_publisher)
      {:noreply, %{state | halted?: true}}
    else
      Process.send_after(self(), :publish, 30_000)
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp report({:ok, _}, %{last: :ok} = state), do: state

  defp report({:ok, _}, state) do
    Audi.Events.emit("audi.host_key_published", host_id: state.client.host_id)
    %{state | last: :ok}
  end

  defp report({:error, reason}, %{last: {:error, reason}} = state), do: state

  defp report({:error, reason}, state) do
    Audi.Events.emit("audi.host_key_publication_failed",
      host_id: state.client.host_id,
      reason: reason
    )

    %{state | last: {:error, reason}}
  end

  @impl true
  # @cc [owner:ghuntley,label:privacy] key-publisher-status-redaction
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
