defmodule Lilly.Execution.Watch do
  @moduledoc """
  The native exit watcher for one verified VMM process (ADR-0140 phase 2).

  The VM actor owns at most one `lilly-vm-watch` port, bound to the PID and
  cgroup of the VMM it last verified. `:exited`, `:error` and `:crashed` are
  terminal for that process and revoke the actor's live proof; a different
  verified VMM requires a new watcher.
  """
  use OverallsProtocol.Machine,
    initial: :absent,
    edges: [
      absent: [start: :starting],
      starting: [armed: :watching, exited: :ended, error: :ended, crashed: :ended, stop: :absent],
      watching: [exited: :ended, error: :ended, crashed: :ended, stop: :absent],
      ended: [stop: :absent]
    ]

  @enforce_keys [:state]
  defstruct [:state, :target, :result]

  @type target :: %{pid: pos_integer(), cgroup: Path.t()}
  @type t :: %__MODULE__{
          state: :absent | :starting | :watching | :ended,
          target: target() | nil,
          result: :exited | :error | :crashed | nil
        }
  @type event :: {:start, target()} | :armed | :exited | :error | :crashed | :stop
  @type effect :: {:open, target()} | :close | {:revoke, :exited | :error | :crashed}

  @spec new() :: t()
  def new, do: %__MODULE__{state: initial()}

  # @cc [owner:ghuntley,label:security;recovery] watch-bound-to-verified-vmm
  # A watcher MUST be opened only for a verified target and only from :absent.
  # Any terminal report or port crash from :starting or :watching MUST emit a
  # revoke effect: an unarmed or lost watcher never extends authority.
  @spec step(t(), event()) :: {:ok, t(), [effect()]} | {:error, :invalid_transition}
  def step(%__MODULE__{state: state} = watch, event) do
    with {:ok, next} <- target(state, name(event)) do
      {:ok, apply_event(%{watch | state: next}, event), effects(state, event)}
    end
  end

  @doc "Whether the watcher is armed on exactly `target`."
  @spec watching?(t(), target()) :: boolean()
  def watching?(%__MODULE__{state: :watching, target: target}, target), do: true
  def watching?(%__MODULE__{}, _target), do: false

  defp name({:start, _}), do: :start
  defp name(event), do: event

  defp apply_event(watch, {:start, target}), do: %{watch | target: target, result: nil}
  defp apply_event(watch, :stop), do: %{watch | target: nil, result: nil}

  defp apply_event(watch, result) when result in [:exited, :error, :crashed],
    do: %{watch | result: result}

  defp apply_event(watch, :armed), do: watch

  defp effects(:absent, {:start, target}), do: [{:open, target}]
  defp effects(_from, :stop), do: [:close]
  defp effects(_from, result) when result in [:exited, :error, :crashed], do: [{:revoke, result}]
  defp effects(_from, _event), do: []
end
