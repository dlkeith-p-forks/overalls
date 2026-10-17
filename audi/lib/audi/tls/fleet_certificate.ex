defmodule Audi.TLS.FleetCertificate do
  @moduledoc """
  The gateway's fleet wildcard certificate lifecycle (ADR-0140 phase 6).

  `:ready` means the installed generation was validated, proven by a local
  verified handshake and acknowledged. A later failed fetch or probe moves to
  `:degraded`: the proven generation keeps serving route readiness, because a
  slow or failed refresh is not evidence the certificate is gone (Marshall
  refuses route reports for a retired generation, and the store refuses an
  expired one). Only expiry, or never having proven a generation, is
  `:unavailable`.
  """
  use OverallsProtocol.Machine,
    initial: :unavailable,
    edges: [
      unavailable: [installed: :ready, failed: :unavailable, expired: :unavailable],
      ready: [installed: :ready, failed: :degraded, expired: :unavailable],
      degraded: [installed: :ready, failed: :degraded, expired: :unavailable]
    ]

  @enforce_keys [:state]
  defstruct [:state, :generation, :reason]

  @type state :: :unavailable | :ready | :degraded
  @type t :: %__MODULE__{
          state: state(),
          generation: pos_integer() | nil,
          reason: atom() | nil
        }
  @type event :: {:installed, pos_integer()} | {:failed, atom()} | :expired

  @spec new() :: t()
  def new, do: %__MODULE__{state: initial()}

  # @cc [owner:ghuntley,label:security;recovery] audi-fleet-certificate-machine
  # Only a validated, proven and acknowledged installation reaches :ready. A
  # failed refresh MUST keep the last proven generation serving (:degraded),
  # never drop readiness; expiry MUST end it (:unavailable). serving/1 is the
  # only source of the generation that per-VM readiness may report.
  @spec step(t(), event()) :: {:ok, t()} | {:error, :invalid_transition}
  def step(%__MODULE__{state: state} = machine, event) do
    with {:ok, next} <- target(state, name(event)) do
      {:ok, apply_event(%{machine | state: next}, event)}
    end
  end

  @doc "The generation per-VM readiness may serve, if any."
  @spec serving(t()) :: pos_integer() | nil
  def serving(%__MODULE__{state: state, generation: generation})
      when state in [:ready, :degraded],
      do: generation

  def serving(%__MODULE__{}), do: nil

  defp name({:installed, _}), do: :installed
  defp name({:failed, _}), do: :failed
  defp name(:expired), do: :expired

  defp apply_event(machine, {:installed, generation}),
    do: %{machine | generation: generation, reason: nil}

  defp apply_event(machine, {:failed, reason}), do: %{machine | reason: reason}
  defp apply_event(machine, :expired), do: %{machine | generation: nil, reason: :expired}
end
