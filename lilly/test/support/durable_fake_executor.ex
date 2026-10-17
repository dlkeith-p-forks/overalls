defmodule Lilly.Test.DurableFakeExecutor do
  @moduledoc "Durable model of the launch marker and running-unit adoption boundary."
  @behaviour Lilly.VM.Executor

  alias Lilly.Host.PrivateFiles

  @type state :: %{
          required(String.t()) => non_neg_integer() | String.t() | %{String.t() => pos_integer()}
        }
  @type context :: Path.t() | {Path.t(), pid()}

  # @cc [owner:ghuntley,label:recovery] antithesis-fake-launch-once
  # A running fake unit MUST be adopted without another launch. A stopped unit
  # with an equal or newer durable attempt marker MUST fail closed. A new marker
  # MUST be written before publishing the running observation.
  @impl true
  @spec reconcile(context(), OverallsProtocol.Execution.command(), map()) ::
          Lilly.VM.Executor.result()
  def reconcile(context, command, _history) do
    {directory, pause_owner} =
      case context do
        {path, owner} -> {path, owner}
        path -> {path, nil}
      end

    key = {command.execution_epoch, command.generation}
    attempt_key = "#{command.placement_id}:#{command.execution_epoch}:#{command.generation}"
    path = Path.join(directory, "fake-executor.json")
    current = read(path)
    previous = {current["epoch"], current["generation"]}

    cond do
      command.kind in [:provision, :start] and current["status"] == "running" and
        previous == key and Map.get(current["attempts"], attempt_key) == 1 ->
        {:ok, facts(:running)}

      command.kind in [:provision, :start] and previous >= key ->
        {:ok, %{facts(:failed) | reason: :execution_failed}}

      command.kind in [:provision, :start] ->
        attempts = Map.update(current["attempts"], attempt_key, 1, &(&1 + 1))

        next = %{
          "epoch" => command.execution_epoch,
          "generation" => command.generation,
          "status" => "attempted",
          "attempts" => attempts
        }

        :ok = persist(directory, next)
        pause_after_attempt(pause_owner)
        :ok = persist(directory, %{next | "status" => "running"})
        {:ok, facts(:running)}

      command.kind == :stop and known_incarnation?(current, key, attempt_key) and
          current["status"] in ["running", "stopped"] ->
        :ok = persist(directory, %{current | "status" => "stopped"})
        {:ok, facts(:stopped)}

      command.kind == :delete and known_incarnation?(current, key, attempt_key) and
          current["status"] in ["running", "stopped", "deleted"] ->
        :ok = persist(directory, %{current | "status" => "deleted"})
        {:ok, facts(:deleted)}

      true ->
        {:ok, %{facts(:unknown) | reason: :unknown}}
    end
  end

  @spec pause_after_attempt(pid() | nil) :: :ok
  defp pause_after_attempt(nil), do: :ok

  defp pause_after_attempt(owner) do
    send(owner, {:fake_launch_attempted, self()})

    receive do
      :resume_fake_launch -> :ok
    end
  end

  @spec known_incarnation?(state(), {pos_integer(), pos_integer()}, String.t()) :: boolean()
  defp known_incarnation?(current, key, attempt_key) do
    {current["epoch"], current["generation"]} == key and
      Map.get(current["attempts"], attempt_key) == 1
  end

  @spec read(Path.t()) :: state()
  def read(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        %{"epoch" => 0, "generation" => 0, "status" => "stopped", "attempts" => %{}}

      {:ok, _} ->
        {:ok, bytes} = PrivateFiles.read_secret(path)
        value = JSON.decode!(bytes)
        true = valid_state?(value)
        value
    end
  end

  @spec valid_state?(term()) :: boolean()
  defp valid_state?(%{
         "epoch" => epoch,
         "generation" => generation,
         "status" => status,
         "attempts" => attempts
       }) do
    is_integer(epoch) and epoch >= 0 and is_integer(generation) and generation >= 0 and
      status in ["stopped", "attempted", "running", "deleted"] and is_map(attempts) and
      Enum.all?(attempts, fn {key, count} ->
        is_binary(key) and is_integer(count) and count > 0
      end)
  end

  defp valid_state?(_), do: false

  @spec persist(Path.t(), state()) :: :ok
  defp persist(directory, state),
    do: PrivateFiles.write(directory, "fake-executor.json", JSON.encode!(state))

  @spec facts(:running | :stopped | :deleted | :failed | :unknown) ::
          Lilly.VM.Executor.observation()
  defp facts(status),
    do: %{
      state: status,
      compute_empty: status != :running,
      disk_present: status not in [:deleted, :unknown],
      cleanup_complete: status == :deleted,
      reason: :none
    }
end
