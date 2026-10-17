defmodule Ziggy.Spool do
  @moduledoc "Bounded metadata journal. Recovery returns events, never executable requests."
  use GenServer
  import Bitwise
  require Ziggy.Events
  alias Ziggy.{SLO, SLOCheckpoint}
  @slot_bytes 16_384
  @type state :: %{
          directory: String.t(),
          maximum: pos_integer(),
          entries: %{String.t() => map()},
          failed: boolean(),
          monitors: %{reference() => String.t()},
          slo: SLO.t(),
          counted: SLOCheckpoint.seen(),
          slo_path: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  @spec admit(GenServer.server(), map()) :: :ok | {:error, atom()}
  def admit(server, event), do: GenServer.call(server, {:admit, event})
  @spec complete(GenServer.server(), binary(), map()) :: :ok | {:error, atom()}
  def complete(server, id, result), do: GenServer.call(server, {:complete, id, result})
  @spec pending(GenServer.server()) :: [map()]
  def pending(server), do: GenServer.call(server, :pending)
  @spec completed(GenServer.server(), pos_integer()) :: [map()]
  def completed(server, limit), do: GenServer.call(server, {:completed, limit})
  @spec acknowledge(GenServer.server(), binary()) :: :ok | {:error, atom()}
  def acknowledge(server, id), do: GenServer.call(server, {:ack, id})

  @spec metrics(GenServer.server()) :: map()
  def metrics(server), do: GenServer.call(server, :metrics)

  @spec slo_snapshot(GenServer.server()) :: SLO.snapshot()
  def slo_snapshot(server), do: GenServer.call(server, :slo_snapshot)

  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server), do: GenServer.call(server, :ready)

  # @cc [owner:ghuntley,label:durability;recovery] ziggy-empty-source-lifetime
  # Startup MUST fsync the initial aggregate before readiness or source
  # publication, even with no admissions. Failure MUST refuse startup.
  @impl true
  def init(opts) do
    directory = Keyword.fetch!(opts, :directory)
    maximum = Keyword.fetch!(opts, :max_requests)

    with true <- is_integer(maximum) and maximum > 0,
         true <- Path.type(directory) == :absolute and Path.expand(directory) == directory,
         :ok <- private_directory(directory),
         {:ok, files} <- File.ls(directory),
         files = files -- SLOCheckpoint.names(),
         {:ok, entries} <-
           recover(directory, Enum.reject(files, &String.ends_with?(&1, ".pending"))),
         {:ok, slo, counted} <- SLOCheckpoint.load(directory, maximum),
         true <-
           Enum.all?(counted, fn id ->
             not Map.has_key?(entries, id) or is_map(entries[id]["completion"])
           end),
         :ok <- clear_staging(directory, files, entries),
         :ok <- SLOCheckpoint.save(directory, slo, counted, maximum) do
      if entries != %{},
        do: Ziggy.Events.emit("ziggy.spool_recovered", [])

      Process.send_after(self(), :slo_publish, 5_000)

      {:ok,
       %{
         directory: directory,
         maximum: maximum,
         entries: entries,
         failed: false,
         monitors: %{},
         slo: slo,
         counted: MapSet.intersection(counted, MapSet.new(Map.keys(entries))),
         slo_path: System.get_env("ZIGGY_SLO_SNAPSHOT")
       }, {:continue, :recover}}
    else
      _ ->
        Ziggy.Events.emit("ziggy.spool_failed", reason: :invalid_spool)
        {:stop, :invalid_spool}
    end
  end

  # @cc [owner:ghuntley,label:recovery] spool-durable-before-effect
  # Successful admission MUST fsync a complete metadata slot and its directory
  # before returning. Each admission reserves bounded completion capacity. Any
  # uncertain write MUST fence new admissions until recovery. Recovery MUST NOT
  # replay inference or reinterpret admission as successful provider usage.
  @impl true
  def handle_call({:admit, event}, {owner, _}, state) do
    id = event["request_id"]

    cond do
      state.failed ->
        admission_rejected(id, :spool_unavailable)
        {:reply, {:error, :spool_unavailable}, state}

      not valid_admission?(event) ->
        admission_rejected(id, :invalid_event)
        {:reply, {:error, :invalid_event}, state}

      Map.has_key?(state.entries, id) ->
        admission_rejected(id, :duplicate_request)
        {:reply, {:error, :duplicate_request}, state}

      map_size(state.entries) >= state.maximum ->
        admission_rejected(id, :spool_full)
        {:reply, {:error, :spool_full}, state}

      true ->
        case persist(state, id, %{"admission" => event, "completion" => nil}, :exclusive) do
          {:reply, :ok, next} ->
            ref = Process.monitor(owner)
            {:reply, :ok, %{next | monitors: Map.put(next.monitors, ref, id)}}

          other ->
            other
        end
    end
  end

  def handle_call({:complete, _, _}, _, %{failed: true} = state),
    do: {:reply, {:error, :spool_unavailable}, state}

  def handle_call({:complete, id, result}, _, state) do
    case Map.fetch(state.entries, id) do
      {:ok, %{"completion" => nil} = entry} ->
        if valid_completion?(result),
          do: persist(state, id, %{entry | "completion" => result}, :replace),
          else: {:reply, {:error, :invalid_event}, state}

      {:ok, %{"completion" => ^result}} ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :invalid_transition}, state}
    end
  end

  def handle_call(:metrics, _, state) do
    active = Enum.count(state.entries, fn {_, entry} -> is_nil(entry["completion"]) end)

    {:reply,
     %{
       "ziggy_active_requests" => active,
       "ziggy_pending_receipts" => map_size(state.entries) - active,
       "ziggy_spool_capacity" => state.maximum,
       "ziggy_spool_available" => if(state.failed, do: 0, else: 1)
     }, state}
  end

  def handle_call(:slo_snapshot, _, state), do: {:reply, SLO.snapshot(state.slo), state}

  def handle_call(:ready, _, state),
    do: {:reply, not state.failed and map_size(state.entries) < state.maximum, state}

  def handle_call({:completed, limit}, _, state) when limit in 1..128 do
    events =
      state.entries
      |> Stream.map(&elem(&1, 1))
      |> Stream.filter(&is_map(&1["completion"]))
      |> Enum.take(limit)

    {:reply, events, state}
  end

  def handle_call(:pending, _, state), do: {:reply, Map.values(state.entries), state}

  # Only after Marshall acknowledges the exact immutable completion. Incomplete
  # admissions survive recovery and are finalized as unknown by the reconciler.
  def handle_call({:ack, _}, _, %{failed: true} = state),
    do: {:reply, {:error, :spool_unavailable}, state}

  def handle_call({:ack, id}, _, state) do
    case state.entries[id] do
      %{"completion" => completion} when is_map(completion) ->
        with true <- MapSet.member?(state.counted, id),
             :ok <- File.rm(path(state, id)),
             :ok <- sync_directory(state.directory) do
          next = %{
            state
            | entries: Map.delete(state.entries, id),
              counted: MapSet.delete(state.counted, id)
          }

          checkpoint_reply(next)
        else
          _ ->
            Ziggy.Events.emit("ziggy.spool_ack_failed", request_id: id)
            {:reply, {:error, :spool_unavailable}, %{state | failed: true}}
        end

      _ ->
        {:reply, {:error, :invalid_transition}, state}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    next =
      Enum.reduce(state.entries, state, fn
        _, %{failed: true} = acc ->
          acc

        {id, %{"completion" => nil}}, acc ->
          interrupt(acc, id)

        {id, %{"completion" => completion}}, acc ->
          count_completion(acc, id, completion)
      end)

    if next.failed do
      {:noreply, next}
    else
      {:reply, _, persisted} = checkpoint_reply(next)
      {:noreply, persisted}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    {id, monitors} = Map.pop(state.monitors, ref)
    next = %{state | monitors: monitors}
    {:noreply, if(id, do: interrupt(next, id), else: next)}
  end

  def handle_info(:slo_publish, state) do
    publish_slo(state)
    Process.send_after(self(), :slo_publish, 5_000)
    {:noreply, state}
  end

  defp interrupt(state, id) do
    case state.entries[id] do
      %{"completion" => nil} = entry ->
        result = %{
          "outcome" => "interrupted",
          "tokens" => %{},
          "completeness" => "unknown",
          "duration_ms" => nil,
          "request_bytes" => nil,
          "response_bytes" => nil
        }

        {:reply, _, next} = persist(state, id, %{entry | "completion" => result}, :replace)
        next

      _ ->
        state
    end
  end

  defp persist(state, id, event, mode) do
    data = Jason.encode!(event)

    if byte_size(data) <= @slot_bytes - 4 do
      padding = :binary.copy(<<0>>, @slot_bytes - 4 - byte_size(data))
      bytes = <<byte_size(data)::32, data::binary, padding::binary>>
      destination = path(state, id)
      stage = destination <> ".pending"
      target = if mode == :exclusive, do: destination, else: stage

      result =
        with :ok <- write(target, bytes),
             :ok <- if(mode == :replace, do: File.rename(stage, destination), else: :ok),
             do: sync_directory(state.directory)

      case result do
        :ok ->
          state = if is_map(event["completion"]), do: release_monitor(state, id), else: state

          state = %{state | entries: Map.put(state.entries, id, event)}
          state = count_completion(state, id, event["completion"])
          checkpoint_reply(state)

        _ ->
          Ziggy.Events.emit("ziggy.spool_failed", reason: :spool_unavailable)
          {:reply, {:error, :spool_unavailable}, %{state | failed: true}}
      end
    else
      {:reply, {:error, :invalid_event}, state}
    end
  end

  # @cc [owner:ghuntley,label:durability;recovery] ziggy-durable-slo-replay
  # A terminal slot MUST enter the fsynced
  # aggregate once before acknowledgement
  # can remove it. Restart MUST replay uncounted terminal slots and preserve
  # acknowledged totals and source lifetime; unfinished admissions become one
  # interrupted failure. An uncertain checkpoint fences admission and ACKs.
  @spec count_completion(state(), String.t(), map() | nil) :: state()
  defp count_completion(state, _, nil), do: state

  defp count_completion(state, id, completion) do
    if MapSet.member?(state.counted, id) do
      state
    else
      %{state | slo: SLO.record(state.slo, completion), counted: MapSet.put(state.counted, id)}
    end
  end

  @spec checkpoint_reply(state()) :: {:reply, :ok | {:error, :spool_unavailable}, state()}
  defp checkpoint_reply(state) do
    case SLOCheckpoint.save(state.directory, state.slo, state.counted, state.maximum) do
      :ok ->
        {:reply, :ok, state}

      _ ->
        Ziggy.Events.emit("ziggy.spool_failed", reason: :spool_unavailable)
        {:reply, {:error, :spool_unavailable}, %{state | failed: true}}
    end
  end

  defp admission_rejected(id, reason) do
    if OverallsProtocol.uuid?(id) do
      Ziggy.Events.emit("ziggy.admission_rejected", request_id: id, reason: reason)
    else
      Ziggy.Events.emit("ziggy.admission_rejected", reason: reason)
    end
  end

  defp release_monitor(state, id) do
    monitors =
      Enum.reduce(state.monitors, state.monitors, fn {ref, request}, acc ->
        if request == id do
          Process.demonitor(ref, [:flush])
          Map.delete(acc, ref)
        else
          acc
        end
      end)

    %{state | monitors: monitors}
  end

  defp write(path, bytes) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:raw, :binary, :write, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600), :ok <- :file.write(file, bytes), do: :file.sync(file)
      after
        :file.close(file)
      end
    end
  end

  defp recover(directory, files) do
    Enum.reduce_while(files, {:ok, %{}}, fn name, {:ok, acc} ->
      id = String.replace_suffix(name, ".json", "")

      with true <- name == id <> ".json" and OverallsProtocol.uuid?(id),
           {:ok, %File.Stat{type: :regular, size: @slot_bytes, mode: mode}} <-
             File.lstat(Path.join(directory, name)),
           true <- band(mode, 0o077) == 0,
           {:ok, <<length::32, rest::binary>>} <- File.read(Path.join(directory, name)),
           true <- length <= byte_size(rest),
           {:ok, %{"admission" => admission, "completion" => completion} = event} <-
             Jason.decode(binary_part(rest, 0, length)),
           true <- admission["request_id"] == id and valid_admission?(admission),
           true <- is_nil(completion) or valid_completion?(completion) do
        {:cont, {:ok, Map.put(acc, id, event)}}
      else
        _ -> {:halt, {:error, :corrupt_spool}}
      end
    end)
  end

  defp clear_staging(directory, files, entries) do
    Enum.reduce_while(Enum.filter(files, &String.ends_with?(&1, ".pending")), :ok, fn name, :ok ->
      id = String.replace_suffix(name, ".json.pending", "")

      with true <- name == id <> ".json.pending" and Map.has_key?(entries, id),
           {:ok, %File.Stat{type: :regular}} <- File.lstat(Path.join(directory, name)),
           :ok <- File.rm(Path.join(directory, name)),
           :ok <- sync_directory(directory) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :corrupt_spool}}
      end
    end)
  end

  defp valid_admission?(event) when is_map(event) do
    Enum.sort(Map.keys(event)) ==
      Enum.sort(
        ~w(request_id host_id vm_id placement_id execution_epoch owner_id provider model operation admitted_at)
      ) and
      Enum.all?(
        ~w(request_id host_id vm_id placement_id owner_id),
        &OverallsProtocol.uuid?(event[&1])
      ) and
      is_integer(event["execution_epoch"]) and event["execution_epoch"] > 0 and
      event["provider"] in ["openai", "anthropic"] and Ziggy.Route.valid_model?(event["model"]) and
      event["operation"] in ["responses", "chat", "messages", "count_tokens"] and
      is_integer(event["admitted_at"]) and event["admitted_at"] > 0
  end

  defp valid_admission?(_), do: false

  defp valid_completion?(event), do: match?({:ok, _}, Ziggy.Completion.validate(event))

  # @cc [owner:ghuntley,label:security;reliability] ziggy-private-slo-file
  # Publication MUST atomically replace only fixed numeric outcomes in the
  # private runtime directory; failure MUST NOT change inference admission.
  defp publish_slo(%{slo_path: nil}), do: :ok
  defp publish_slo(%{failed: true}), do: :ok

  defp publish_slo(%{slo_path: path, slo: slo}) do
    staged = path <> ".new"

    with :ok <- File.write(staged, Jason.encode!(SLO.snapshot(slo))),
         :ok <- File.chmod(staged, 0o600),
         :ok <- File.rename(staged, path) do
      :ok
    else
      _ -> :ok
    end
  end

  defp path(state, id), do: Path.join(state.directory, id <> ".json")

  defp private_directory(directory) do
    with {:ok, %File.Stat{type: :directory, uid: uid, mode: mode}} <- File.lstat(directory),
         {:ok, %File.Stat{uid: ^uid}} <- File.stat("/proc/self"),
         true <- band(mode, 0o077) == 0,
         do: :ok
  end

  defp sync_directory(path) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      try do
        :file.sync(file)
      after
        :file.close(file)
      end
    end
  end
end
