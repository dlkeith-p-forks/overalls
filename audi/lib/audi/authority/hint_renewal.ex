defmodule Audi.Authority.HintRenewal do
  @moduledoc """
  Hint-driven lease renewal for open streams (ADR-0142).

  A stream's renewal worker registers under the VM and user its grant names;
  Marshall's authority hints for either renew the lease at once, so a
  revocation ends the stream without waiting for the next periodic renewal.
  The periodic renewal remains the backstop for a lost hint.
  """

  # @cc [owner:ghuntley,label:security;recovery] stream-renew-on-authority-hint
  # A renewal worker MUST register for its grant's VM and (when present) user
  # hints and renew immediately on one; a refused renewal ends the stream as a
  # periodic one would. Registration grants nothing: renewal still asks Marshall.

  @doc "Registers the calling renewal worker for its grant's VM and user hints."
  @spec register(keyword()) :: :ok
  def register(identities) do
    if Process.whereis(Audi.Control.Hints) do
      for {kind, id} <- [{"vm", identities[:vm]}, {"user", identities[:user]}],
          is_binary(id) do
        {:ok, _} = Registry.register(Audi.Control.Hints, {kind, id}, nil)
      end
    end

    :ok
  end

  @doc """
  Delay before the next periodic renewal of a lease with `remaining`
  milliseconds: short (five-second) leases keep their one-second renewal; long
  leases, whose revocation travels by hint, renew at half their remaining time.
  """
  @spec delay(integer()) :: pos_integer()
  def delay(remaining) when remaining > 5000, do: div(remaining, 2)
  def delay(remaining), do: min(1000, max(div(remaining, 2), 1))
end
