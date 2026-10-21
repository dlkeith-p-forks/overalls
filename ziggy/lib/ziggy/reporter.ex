defmodule Ziggy.Reporter do
  @moduledoc "Retry only immutable accounting; provider requests are never replayed."
  use GenServer
  require Ziggy.Events
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  @impl true
  def init(opts) do
    send(self(), :report)

    {:ok,
     %{
       spool: Keyword.fetch!(opts, :spool),
       control: Keyword.fetch!(opts, :control),
       request: Keyword.get(opts, :request, &Ziggy.Control.request/3),
       fence: Ziggy.VersionFence.new(opts)
     }}
  end

  # @cc [owner:ghuntley,label:recovery] version-refusal-stops-accounting-retry
  # A control API version refusal MUST stop normal-cadence completion retries
  # (Ziggy.VersionFence backs off and probes) while retaining every
  # unacknowledged durable spool receipt; an accepted probe resumes reporting.
  @impl true
  def handle_info(:report, %{fence: fence} = state) do
    if Ziggy.VersionFence.fenced?(fence), do: {:noreply, state}, else: report(state)
  end

  def handle_info({:probe, token}, %{fence: fence} = state) do
    if Ziggy.VersionFence.probe?(fence, token), do: report(state), else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp report(state) do
    version_fenced =
      state.spool
      |> Ziggy.Spool.completed(128)
      |> Enum.reduce_while(false, fn
        %{"admission" => %{"request_id" => id}, "completion" => completion}, _
        when is_map(completion) ->
          case state.request.(state.control, "complete", %{
                 "request_id" => id,
                 "completion" => Ziggy.Completion.wire(completion)
               }) do
            {:ok, %{"acknowledged" => ^id}} ->
              if Ziggy.Spool.acknowledge(state.spool, id) == :ok do
                Ziggy.Events.emit("ziggy.accounting_reported", request_id: id)
              else
                Ziggy.Events.emit("ziggy.accounting_retry", request_id: id, reason: :ack_failed)
              end

              {:cont, false}

            {:error, :unsupported_version} ->
              {:halt, true}

            {:error, :completion_conflict} ->
              Ziggy.Events.emit("ziggy.accounting_retry",
                request_id: id,
                reason: :completion_conflict
              )

              {:cont, false}

            _ ->
              Ziggy.Events.emit("ziggy.accounting_retry",
                request_id: id,
                reason: :authority_unavailable
              )

              {:cont, false}
          end

        _, _ ->
          {:cont, false}
      end)

    if version_fenced do
      {fence, delay, token} = Ziggy.VersionFence.refused(state.fence)
      Process.send_after(self(), {:probe, token}, delay)
      {:noreply, %{state | fence: fence}}
    else
      Process.send_after(self(), :report, 1000)
      {:noreply, %{state | fence: Ziggy.VersionFence.accepted(state.fence)}}
    end
  end
end
