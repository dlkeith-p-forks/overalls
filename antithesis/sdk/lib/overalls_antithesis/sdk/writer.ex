defmodule OverallsAntithesis.SDK.Writer do
  @moduledoc false
  use GenServer

  @max_record 4096
  @port_timeout 1_000
  @call_timeout 1_500
  @slot_key {__MODULE__, :admission}
  @status_key {__MODULE__, :state}

  @type failure ::
          :busy | :invalid | :oversized | :unavailable | :timeout | :uncertain | :poisoned
  @type delivery :: :written | :disabled | :duplicate | {:error, failure()}

  # @cc [owner:ghuntley,label:reliability] sdk-admission-before-mailbox
  # At most one record request may enter the writer mailbox; timeout or uncertain
  # transport MUST poison admission before another record can be admitted.
  @spec submit(map(), binary() | nil) :: delivery()
  def submit(record, dedup_key \\ nil) do
    with {:ok, encoded} <- encode(record),
         {:ok, slot} <- acquire() do
      try do
        case GenServer.call(__MODULE__, {:write, encoded, dedup_key}, @call_timeout) do
          {:error, reason} = error when reason in [:timeout, :uncertain, :poisoned] ->
            :atomics.put(slot, 1, 2)
            error

          result ->
            :atomics.compare_exchange(slot, 1, 1, 0)
            result
        end
      catch
        :exit, _reason ->
          :atomics.put(slot, 1, 2)
          {:error, :uncertain}
      end
    end
  end

  @spec status() :: :ready | :busy | :poisoned | :unavailable | :disabled
  def status do
    case {:persistent_term.get(@slot_key, nil), Process.whereis(__MODULE__)} do
      {nil, _} ->
        :unavailable

      {_, nil} ->
        :unavailable

      {slot, _pid} ->
        case :atomics.get(slot, 1) do
          0 -> :persistent_term.get(@status_key, :unavailable)
          1 -> :busy
          2 -> :poisoned
        end
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    slot =
      case :persistent_term.get(@slot_key, nil) do
        nil ->
          new_slot = :atomics.new(1, signed: false)
          :persistent_term.put(@slot_key, new_slot)
          new_slot

        existing_slot ->
          existing_slot
      end

    output_dir = System.get_env("ANTITHESIS_OUTPUT_DIR")
    helper = System.get_env("OVERALLS_ANTITHESIS_WRITER")
    state_dir = System.get_env("OVERALLS_ANTITHESIS_STATE_DIR")

    cond do
      :atomics.get(slot, 1) != 0 ->
        :atomics.put(slot, 1, 2)
        :persistent_term.put(@status_key, :poisoned)
        {:ok, %{port: nil, state: :poisoned, seen: MapSet.new()}}

      is_nil(output_dir) ->
        :persistent_term.put(@status_key, :disabled)
        {:ok, %{port: nil, state: :disabled, seen: MapSet.new()}}

      not valid_path?(output_dir) or not valid_path?(helper) or not valid_path?(state_dir) ->
        :persistent_term.put(@status_key, :unavailable)
        {:ok, %{port: nil, state: :unavailable, seen: MapSet.new()}}

      true ->
        path = Path.join(output_dir, "sdk.jsonl")

        try do
          port =
            Port.open(
              {:spawn_executable, String.to_charlist(helper)},
              [:binary, :exit_status, {:packet, 4}, {:args, [path, state_dir]}]
            )

          :persistent_term.put(@status_key, :ready)
          {:ok, %{port: port, state: :ready, seen: MapSet.new()}}
        rescue
          ArgumentError ->
            :persistent_term.put(@status_key, :unavailable)
            {:ok, %{port: nil, state: :unavailable, seen: MapSet.new()}}
        end
    end
  end

  @impl true
  def handle_call({:write, _encoded, _key}, _from, %{state: :disabled} = state),
    do: {:reply, :disabled, state}

  def handle_call({:write, _encoded, _key}, _from, %{state: :unavailable} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:write, _encoded, _key}, _from, %{state: :poisoned} = state),
    do: {:reply, {:error, :poisoned}, state}

  def handle_call({:write, encoded, key}, _from, state) do
    if key != nil and MapSet.member?(state.seen, key) do
      {:reply, :duplicate, state}
    else
      case port_write(state.port, encoded) do
        :written ->
          seen = if key == nil, do: state.seen, else: MapSet.put(state.seen, key)
          {:reply, :written, %{state | seen: seen}}

        error ->
          :persistent_term.put(@status_key, :poisoned)
          {:reply, error, %{state | state: :poisoned}}
      end
    end
  end

  @impl true
  def handle_info({_port, {:exit_status, _status}}, state) do
    case :persistent_term.get(@slot_key, nil) do
      nil -> :ok
      slot -> :atomics.put(slot, 1, 2)
    end

    :persistent_term.put(@status_key, :poisoned)
    {:noreply, %{state | state: :poisoned}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec port_write(port(), binary()) :: :written | {:error, :uncertain | :timeout}
  defp port_write(port, encoded) do
    if Port.command(port, encoded) do
      receive do
        {^port, {:data, "W"}} -> :written
        {^port, {:data, "P"}} -> {:error, :uncertain}
        {^port, {:data, _other}} -> {:error, :uncertain}
        {^port, {:exit_status, _}} -> {:error, :uncertain}
      after
        @port_timeout -> {:error, :timeout}
      end
    else
      {:error, :uncertain}
    end
  rescue
    ArgumentError -> {:error, :uncertain}
  end

  @spec acquire() :: {:ok, reference()} | {:error, :busy | :poisoned | :unavailable}
  defp acquire do
    case :persistent_term.get(@slot_key, nil) do
      nil ->
        {:error, :unavailable}

      slot ->
        case :atomics.compare_exchange(slot, 1, 0, 1) do
          :ok -> {:ok, slot}
          1 -> {:error, :busy}
          2 -> {:error, :poisoned}
        end
    end
  end

  @spec encode(map()) :: {:ok, binary()} | {:error, :invalid | :oversized}
  defp encode(record) do
    line = Jason.encode!(record) <> "\n"

    cond do
      byte_size(line) > @max_record ->
        {:error, :oversized}

      String.contains?(binary_part(line, 0, byte_size(line) - 1), ["\n", "\r"]) ->
        {:error, :invalid}

      true ->
        {:ok, line}
    end
  rescue
    Jason.EncodeError -> {:error, :invalid}
  end

  @spec valid_path?(binary() | nil) :: boolean()
  defp valid_path?(path),
    do:
      is_binary(path) and Path.type(path) == :absolute and
        not String.contains?(path, ["\0", "\n", "\r"])
end
