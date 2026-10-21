defmodule Audi.TLS.Readiness do
  @moduledoc "Bounded independent readiness jobs under a current catalog snapshot."
  use GenServer, restart: :temporary
  require Audi.Events
  @limit 16
  @refresh 1000

  @type state :: %{
          owner: reference(),
          owner_pid: pid(),
          halted?: boolean(),
          tasks: GenServer.server(),
          work: (map(), pos_integer() -> {:ok, map()} | {:error, atom()} | :ok | nil),
          entries: %{binary() => {map(), pos_integer()}},
          due: %{binary() => integer()},
          jobs: %{reference() => %{pid: pid(), entry: map()}},
          expiry: integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  # @cc [owner:ghuntley,label:concurrency;security] audi-readiness-independent-progress
  # At most sixteen jobs may run; a VM MUST NOT have overlapping jobs. Healthy
  # jobs MUST become due independently of unfinished jobs. A slot is reusable
  # only after monitored job death, including cancellation. Every launch MUST use
  # an unexpired catalog and its preallocated revision. Changed/removed bindings,
  # catalog expiry and owner death MUST cancel jobs. No job may survive its owner
  # or its original catalog deadline, even when this scheduler is suspended.
  @spec refresh(GenServer.server(), [{map(), pos_integer()}], integer()) ::
          :ok | {:error, :unsupported_version}
  def refresh(server, entries, expiry), do: GenServer.call(server, {:refresh, entries, expiry})

  @impl true
  def init(options) do
    :logger.update_process_metadata(%{audi_private: true})
    send(self(), :tick)

    {:ok,
     %{
       owner: Process.monitor(Keyword.fetch!(options, :owner)),
       owner_pid: Keyword.fetch!(options, :owner),
       halted?: false,
       tasks: Keyword.fetch!(options, :tasks),
       work: Keyword.fetch!(options, :work),
       entries: %{},
       due: %{},
       jobs: %{},
       expiry: 0
     }}
  end

  @impl true
  def handle_call({:refresh, _, _}, _, %{halted?: true} = state),
    do: {:reply, {:error, :unsupported_version}, state}

  def handle_call({:refresh, entries, expiry}, _, state) when length(entries) <= 10_000 do
    entries = Map.new(entries, fn {entry, revision} -> {entry.vm_id, {entry, revision}} end)

    Enum.each(state.jobs, fn {ref, job} ->
      case Map.get(entries, job.entry.vm_id) do
        {entry, _} when entry == job.entry -> :ok
        _ -> cancel(ref, job)
      end
    end)

    due =
      Map.new(entries, fn {id, {entry, _}} ->
        deadline =
          case Map.get(state.entries, id) do
            {^entry, _} -> Map.get(state.due, id, now())
            _ -> now()
          end

        {id, deadline}
      end)

    state = %{state | entries: entries, due: due, expiry: expiry}
    {:reply, :ok, dispatch(state)}
  end

  @impl true
  def handle_info(:tick, %{halted?: true} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 250)
    {:noreply, dispatch(state)}
  end

  def handle_info({ref, {:error, :unsupported_version}}, state) when is_reference(ref) do
    if Map.has_key?(state.jobs, ref) and not state.halted? do
      send(state.owner_pid, {:control_version_refused, self()})
      Audi.Events.emit("audi.control_version_refused", owner: :tls_readiness)
      {:noreply, halt_state(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, finish(state, ref)}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  # @cc [owner:ghuntley,label:privacy] readiness-status-redaction
  # Preserve OTP status keys so the runtime accepts redaction; remove payloads
  # from state, messages, reasons and debug logs before status/crash formatting.
  @spec format_status(map()) :: map()
  def format_status(status) do
    Map.new(status, fn
      {:log, _} -> {:log, []}
      {key, _} -> {key, :redacted}
    end)
  end

  defp finish(state, ref) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        state

      {job, jobs} ->
        due =
          case Map.get(state.entries, job.entry.vm_id) do
            {entry, _} when entry == job.entry ->
              Map.put(state.due, job.entry.vm_id, now() + @refresh)

            _ ->
              state.due
          end

        dispatch(%{state | jobs: jobs, due: due})
    end
  end

  defp dispatch(%{halted?: true} = state), do: state

  defp dispatch(state) do
    if state.expiry <= now() do
      Enum.each(state.jobs, fn {ref, job} -> cancel(ref, job) end)
      %{state | entries: %{}, due: %{}}
    else
      running = MapSet.new(state.jobs, fn {_, job} -> job.entry.vm_id end)
      instant = now()

      state.entries
      |> Enum.reject(fn {id, _} -> MapSet.member?(running, id) or state.due[id] > instant end)
      |> Enum.sort_by(fn {id, _} -> {state.due[id], id} end)
      |> Enum.take(@limit - map_size(state.jobs))
      |> Enum.reduce(state, &launch/2)
    end
  end

  defp launch({_, {entry, revision}}, state) do
    owner = self()
    deadline = min(state.expiry, now() + 10_000)
    work = state.work

    task =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        :logger.update_process_metadata(%{audi_private: true})
        job = self()
        token = make_ref()
        spawn_link(fn -> watch(owner, job, token, deadline) end)

        receive do
          {^token, :ready} -> :ok
        end

        if deadline > now(), do: work.(entry, revision)
      end)

    %{state | jobs: Map.put(state.jobs, task.ref, %{pid: task.pid, entry: entry})}
  rescue
    RuntimeError -> state
  catch
    :exit, _ -> state
  end

  defp watch(owner, job, token, deadline) do
    :logger.update_process_metadata(%{audi_private: true})
    owner_ref = Process.monitor(owner)
    job_ref = Process.monitor(job)
    send(job, {token, :ready})

    receive do
      {:DOWN, ^job_ref, :process, _, _} -> :ok
      {:DOWN, ^owner_ref, :process, _, _} -> Process.exit(job, :kill)
    after
      max(deadline - now(), 0) -> Process.exit(job, :kill)
    end
  end

  defp cancel(_ref, job), do: Process.exit(job.pid, :kill)

  # @cc [owner:ghuntley,label:protocol;recovery] audi-readiness-terminal-version
  # Version refusal MUST cancel all owned jobs and prevent queued refreshes or
  # ticks from reopening work. Slot bookkeeping remains until actual job death.
  @spec halt_state(state()) :: state()
  defp halt_state(state) do
    Enum.each(state.jobs, fn {ref, job} -> cancel(ref, job) end)
    %{state | halted?: true, entries: %{}, due: %{}, expiry: 0}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
