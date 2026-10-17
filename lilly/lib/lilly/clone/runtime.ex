defmodule Lilly.Clone.Runtime do
  @moduledoc "Bounded clone polling; bulk copy runs separately from permit renewal and lifecycle."
  use GenServer
  require Lilly.Events
  alias Lilly.Clone.{Effects, Reason}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    state =
      Map.new(options)
      |> Map.merge(%{task: nil, pending: %{}, offered: MapSet.new(), failures: %{}})

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{task: nil} = state) do
    task =
      Task.async(fn ->
        Process.flag(:sensitive, true)

        with {:ok, response} <-
               Lilly.Control.Client.exchange_clone(
                 state.config.client,
                 state.session,
                 Map.values(state.pending)
               ) do
          pending = Map.drop(state.pending, response.acknowledgements)
          offered = MapSet.new(response.commands, & &1["id"])

          response.commands
          |> Enum.reduce({pending, []}, fn command, {pending, attempts} ->
            selected = command["kind"] == "copy" == (state.mode == :copy)

            if selected and not Map.has_key?(pending, command["id"]) and map_size(pending) < 16 do
              case Effects.execute(state.config, state.store, command) do
                {:ok, result} ->
                  {Map.put(pending, command["id"], result), [{command, :ok} | attempts]}

                {:error, internal} ->
                  reason = Reason.classify(internal)

                  result = %{
                    "id" => command["id"],
                    "kind" => command["kind"],
                    "result" => %{"error" => "unconfirmed", "reason" => Atom.to_string(reason)}
                  }

                  {Map.put(pending, command["id"], result),
                   [{command, reason, Reason.stage(internal)} | attempts]}
              end
            else
              {pending, attempts}
            end
          end)
          |> then(fn {next, attempts} ->
            executed = Map.keys(next) -- Map.keys(pending)
            {:ok, next, offered, fresh_execution?(state.offered, executed), attempts}
          end)
        end
      end)

    {:noreply, %{state | task: task}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, pending, offered, fresh, attempts} ->
        Process.send_after(self(), :tick, if(fresh, do: 0, else: 1000))

        {:noreply,
         %{state | pending: pending, offered: offered, task: nil}
         |> report_attempts(attempts)}

      {:error, reason}
      when reason in [:unauthorized, :stale_connection, :invalid_outcome, :outcome_conflict] ->
        send(state.owner, {:clone_fenced, self(), reason})
        {:noreply, %{state | task: nil}}

      _ ->
        Process.send_after(self(), :tick, 5000)
        {:noreply, %{state | task: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state) do
    Process.send_after(self(), :tick, 5000)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  # @cc [owner:ghuntley,label:performance;protocol] clone-results-report-promptly
  # A tick that executed an effect first offered in this exchange MUST report it on
  # an immediate follow-up exchange instead of waiting a polling interval. Effects
  # Marshall re-offers on purpose (capture permit renewal, preparing probes) were
  # already offered last exchange and MUST keep the one-second cadence, so neither
  # re-offers nor unacknowledged results can spin the exchange loop.
  @doc false
  @spec fresh_execution?(MapSet.t(String.t()), [String.t()]) :: boolean()
  def fresh_execution?(previously_offered, executed),
    do: Enum.any?(executed, &(not MapSet.member?(previously_offered, &1)))

  # @cc [owner:ghuntley,label:observability] clone-effect-failure-diagnostics-deduped
  # An unconfirmed effect MUST be reported once per effect and change of its
  # wire reason or internal stage, not once per one-second retry; a later
  # success clears the record so a fresh failure reports again. Only the clone
  # identifier, the fixed utility, the closed reason and the closed internal
  # stage atom are logged; commands and native output never are.
  @doc false
  @spec report_attempts(map(), [{map(), :ok} | {map(), Reason.reason(), atom()}]) :: map()
  def report_attempts(state, attempts) do
    failures =
      Enum.reduce(attempts, state.failures, fn
        {command, :ok}, failures ->
          Map.delete(failures, command["id"])

        {command, reason, stage}, failures ->
          if failures[command["id"]] != {reason, stage}, do: report(command, reason, stage)
          Map.put(failures, command["id"], {reason, stage})
      end)

    %{state | failures: Map.take(failures, MapSet.to_list(state.offered))}
  end

  defp report(command, reason, stage) do
    clone = command["clone_id"]
    utility = Effects.utility(command["kind"])

    cond do
      not OverallsProtocol.uuid?(clone) ->
        :ok

      Reason.contended?(reason) ->
        Lilly.Events.emit("lilly.clone_effect_contended",
          clone_id: clone,
          utility: utility,
          reason: reason,
          stage: stage
        )

      true ->
        Lilly.Events.emit("lilly.clone_effect_unconfirmed",
          clone_id: clone,
          utility: utility,
          reason: reason,
          stage: stage
        )
    end
  end

  @impl true
  def terminate(_, %{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok
  @impl true
  def format_status(status),
    do: Map.put(status, :state, %{pending_results: map_size(status.state.pending)})
end
