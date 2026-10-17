defmodule Lilly.Execution.Liveness do
  @moduledoc """
  Volatile proof that one placement's current command is executing (ADR-0140).

  Owned by the placement's VM actor, the single writer of its boot and live
  rows. A boot proof (owned spec, current boot record and confined VMM) while
  the guest is still booting publishes the boot row, which grants only roster
  authority. A running observation publishes both rows. Slow or contended
  observations are inconclusive and never revoke; definite negative evidence,
  a superseding command, the exit watcher or actor exit does. Every actor
  (re)start begins `:unproven`, so a Lilly restart fails closed.
  """
  use OverallsProtocol.Machine,
    initial: :unproven,
    edges: [
      unproven: [
        observed_booting: :booting,
        observed_running: :live,
        inconclusive: :unproven,
        boot_failed: :unproven,
        revoke: :unproven
      ],
      booting: [
        observed_booting: :booting,
        observed_running: :live,
        watched: :booting,
        inconclusive: :booting,
        boot_failed: :unproven,
        expired: :suspect,
        revoke: :revoked
      ],
      live: [
        observed_running: :live,
        observed_booting: :live,
        watched: :live,
        inconclusive: :live,
        boot_failed: :revoked,
        expired: :suspect,
        revoke: :revoked
      ],
      suspect: [
        observed_booting: :booting,
        observed_running: :live,
        inconclusive: :suspect,
        boot_failed: :suspect,
        revoke: :revoked
      ],
      revoked: [
        observed_booting: :booting,
        observed_running: :live,
        inconclusive: :revoked,
        boot_failed: :revoked,
        revoke: :revoked
      ]
    ]

  @enforce_keys [:state]
  defstruct [:state]

  @type state :: :unproven | :booting | :live | :suspect | :revoked
  @type t :: %__MODULE__{state: state()}
  @type event ::
          :observed_booting
          | :observed_running
          | :watched
          | :inconclusive
          | :boot_failed
          | :expired
          | :revoke
  @type row :: :boot | :live
  @type effect :: {:publish, row()} | {:delete, row()}

  @spec new() :: t()
  def new, do: %__MODULE__{state: initial()}

  @doc "Rows that must exist in a state."
  @spec rows(state()) :: [row()]
  def rows(:live), do: [:boot, :live]
  def rows(:booting), do: [:boot]
  def rows(_state), do: []

  # @cc [owner:ghuntley,label:security;recovery] liveness-row-iff-live
  # The owner MUST hold exactly rows(state): the boot row in :booting and :live,
  # the live row only in :live. Entering or renewing a state with rows
  # republishes them (fresh deadline); leaving it deletes those no longer held.
  # An inconclusive observation MUST neither publish nor delete. A fresh
  # machine is :unproven with no rows.
  @spec step(t(), event()) :: {:ok, t(), [effect()]} | {:error, :invalid_transition}
  def step(%__MODULE__{state: state} = liveness, event) do
    with {:ok, next} <- target(state, event) do
      {:ok, %{liveness | state: next}, effects(state, next, event)}
    end
  end

  defp effects(_from, _to, :inconclusive), do: []
  # A boot proof while already live is not running evidence: keep both rows as is.
  defp effects(:live, :live, :observed_booting), do: []

  defp effects(from, to, _event) do
    deleted = for row <- rows(from), row not in rows(to), do: {:delete, row}
    published = for row <- rows(to), do: {:publish, row}
    deleted ++ published
  end
end
