defmodule Lilly.VM.Intent do
  @moduledoc "Durable placement/epoch/generation authority shared with the in-service native launch guard."
  alias Lilly.Host.{Lock, PrivateFiles}
  @maximum 9_223_372_036_854_775_807
  @states %{stopped: 0, running: 1, deleted: 2, failed: 3, paused: 4}
  @type state :: :stopped | :running | :deleted | :failed | :paused
  @type revision :: {pos_integer(), pos_integer() | nil}
  @type t :: %{
          placement_id: OverallsProtocol.uuid(),
          execution_epoch: pos_integer(),
          generation: pos_integer(),
          state: state()
        }

  @spec path(Path.t()) :: Path.t()
  def path(directory), do: Path.join(directory, "intent.bin")

  @spec lock_directory(Path.t()) :: Path.t()
  def lock_directory(directory), do: Path.join(directory, "launch")

  @spec lock_path(Path.t()) :: Path.t()
  def lock_path(directory), do: Path.join(lock_directory(directory), "owner.lock")

  @doc "Caller holds the per-VM lock. A nil generation is reserved for local operator primitives."
  # @cc [owner:ghuntley,label:recovery] launch-intent-monotonic-and-terminal
  # set/4 MUST reject changed placement, decreasing epoch/generation pairs and equal-pair state conflicts, except running
  # or paused may become failed. Failed intent cannot return to running at the same epoch/generation, and deleted
  # intent can never become non-deleted.
  @spec set(Path.t(), OverallsProtocol.uuid(), revision(), state()) ::
          {:ok, t()} | {:error, atom()}
  def set(directory, placement, revision, state) when is_map_key(@states, state) do
    with true <- OverallsProtocol.uuid?(placement),
         {:ok, port} <- Lock.acquire(lock_directory(directory)) do
      try do
        with {:ok, current} <- read(directory),
             {:ok, next} <- transition(current, placement, revision, state) do
          if current == next do
            {:ok, next}
          else
            with :ok <-
                   PrivateFiles.write(
                     directory,
                     "intent.bin",
                     <<next.placement_id::binary-size(36), next.execution_epoch::unsigned-big-64,
                       next.generation::unsigned-big-64, Map.fetch!(@states, next.state)>>
                   ),
                 do: {:ok, next}
          end
        end
      after
        Lock.release(port)
      end
    else
      false -> {:error, :invalid_placement}
      error -> error
    end
  end

  # @cc [owner:ghuntley,label:protocol;recovery] launch-intent-fixed-native-encoding
  # read/1 MUST distinguish a missing intent from corrupt state and accept only 53 bytes: a
  # canonical placement UUID, positive signed-64-bit-range epoch/generation and known state code. This encoding must
  # remain compatible with lilly-launch-guard.
  @spec read(Path.t()) :: {:ok, t() | nil} | {:error, atom()}
  def read(directory) do
    case File.lstat(path(directory)) do
      {:error, :enoent} ->
        {:ok, nil}

      {:ok, _} ->
        with {:ok,
              <<placement::binary-size(36), epoch::unsigned-big-64, generation::unsigned-big-64,
                code>>} <-
               PrivateFiles.read_secret(path(directory)),
             true <-
               OverallsProtocol.uuid?(placement) and epoch in 1..@maximum and
                 generation in 1..@maximum,
             {state, ^code} <- Enum.find(@states, fn {_state, value} -> value == code end) do
          {:ok,
           %{
             placement_id: placement,
             execution_epoch: epoch,
             generation: generation,
             state: state
           }}
        else
          _ -> {:error, :invalid_launch_intent}
        end

      _ ->
        {:error, :invalid_launch_intent}
    end
  end

  defp transition(current, placement, {epoch, nil}, state) do
    generation =
      cond do
        current == nil -> 1
        current.execution_epoch != epoch -> 1
        current.state == state -> current.generation
        true -> current.generation + 1
      end

    transition(current, placement, {epoch, generation}, state)
  end

  defp transition(current, placement, {epoch, generation}, state)
       when is_integer(epoch) and epoch in 1..@maximum and
              is_integer(generation) and generation in 1..@maximum do
    next = %{
      placement_id: placement,
      execution_epoch: epoch,
      generation: generation,
      state: state
    }

    cond do
      current == nil ->
        {:ok, next}

      current.placement_id != placement ->
        {:error, :placement_identity_conflict}

      {epoch, generation} < {current.execution_epoch, current.generation} ->
        {:error, :stale_generation}

      current.state == :deleted and state != :deleted ->
        {:error, :vm_deleted}

      {epoch, generation} > {current.execution_epoch, current.generation} ->
        {:ok, next}

      current.state == state ->
        {:ok, current}

      current.state in [:running, :paused] and state == :failed ->
        {:ok, %{current | state: :failed}}

      true ->
        {:error, :generation_conflict}
    end
  end

  defp transition(_, _, _, _), do: {:error, :invalid_generation}
end
