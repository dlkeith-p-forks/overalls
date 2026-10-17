defmodule Marshall.Control.Hints.Relay do
  @moduledoc """
  Per-node delivery of control hints.

  Listens on the hint notifier channel and rebroadcasts each validated hint on
  this node. Oban drops notifications while its listener connection is down and
  gives listeners no reconnect signal, so the relay also watches the notifier's
  status: when it leaves `:isolated`, every local subscriber is told to resync.
  """
  use GenServer
  require Marshall.Events

  alias Marshall.Control.Hints

  @handler __MODULE__

  # @cc [owner:ghuntley,label:verification] hint-recovery-antithesis-anchor
  # Only a harness-built release declares and emits the notifier-recovery
  # anchor, and only on an observed :isolated to connected transition. The
  # anchor marks that hints may have been lost; it MUST NOT be read as proof
  # that a committed host command or authority was reconciled afterwards.
  # The production module has no SDK call or runtime switch.
  if System.get_env("ANTITHESIS_HARNESS") == "1" do
    Code.eval_quoted(
      quote location: :keep do
        require OverallsAntithesis.SDK

        @spec harness_declare() :: :ok
        defp harness_declare do
          _ = OverallsAntithesis.SDK.declare_catalog([__MODULE__])
          :ok
        end

        @spec harness_recovered() :: :ok
        defp harness_recovered do
          _ =
            OverallsAntithesis.SDK.reachable(
              "Marshall notifier recovered after losing a host command hint"
            )

          :ok
        end
      end,
      [],
      __ENV__
    )
  else
    @spec harness_declare() :: :ok
    defp harness_declare, do: :ok

    @spec harness_recovered() :: :ok
    defp harness_recovered, do: :ok
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    :ok = Oban.Notifier.listen(Oban, Hints.channel())
    relay = self()

    :telemetry.attach(
      {@handler, relay},
      [:oban, :notifier, :switch],
      &__MODULE__.notifier_switched/4,
      relay
    )

    harness_declare()
    {:ok, %{notifier: :unknown}}
  end

  @doc false
  @spec notifier_switched([atom()], map(), map(), pid()) :: :ok
  def notifier_switched(_event, _measurements, metadata, relay) do
    send(relay, {:notifier_status, Map.get(metadata, :status)})
    :ok
  end

  # @cc [owner:ghuntley,label:recovery] hint-resync-on-notifier-recovery
  # Hints lost while the notifier was isolated MUST NOT go unnoticed: a
  # transition to a connected status MUST make every local subscriber resync.
  # The relay tracks the last reported notifier status so that only a
  # connected status following :isolated counts as recovery after hint loss.
  @impl true
  def handle_info({:notification, channel, payload}, state) do
    if channel == Hints.channel(), do: Hints.deliver(payload)
    {:noreply, state}
  end

  def handle_info({:notifier_status, status}, state) when status in [:solitary, :clustered] do
    Hints.resync_local()
    Marshall.Events.emit("control.hints_resynced", next_state: status)
    if Map.get(state, :notifier) == :isolated, do: harness_recovered()
    {:noreply, Map.put(state, :notifier, status)}
  end

  def handle_info({:notifier_status, status}, state) when is_atom(status),
    do: {:noreply, Map.put(state, :notifier, status)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach({@handler, self()})
    :ok
  end
end
