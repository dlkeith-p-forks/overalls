defmodule OverallsProtocol.Control.Close do
  @moduledoc """
  Closed WebSocket close codes of the control protocol and the reaction each
  one requires of a client.
  """

  @codes %{
    refused: 4000,
    unsupported_version: 4001,
    fenced: 4002,
    superseded: 4003,
    overloaded: 4004,
    protocol_violation: 4005,
    reauthenticate: 4006,
    draining: 4007,
    idle: 4008
  }
  @reasons Map.new(@codes, fn {reason, code} -> {code, reason} end)

  @type reason ::
          :refused
          | :unsupported_version
          | :fenced
          | :superseded
          | :overloaded
          | :protocol_violation
          | :reauthenticate
          | :draining
          | :idle
  @type reaction :: :stop | :fence | :reconnect | :reconnect_now | :reload_credential

  @doc "The close code for a reason."
  @spec code(reason()) :: 4000..4008
  def code(reason), do: Map.fetch!(@codes, reason)

  @doc "The reason for a received code; any other or missing code is a plain loss."
  @spec reason(non_neg_integer() | nil) :: reason() | :lost
  def reason(code), do: Map.get(@reasons, code, :lost)

  # @cc [owner:ghuntley,label:protocol;recovery] control-close-reaction
  # Every close reason MUST map to exactly one client reaction: stop on an
  # unsupported version, fence on fenced, reload the credential on refused or
  # reauthenticate, reconnect at once when draining, otherwise reconnect with
  # jittered backoff. An unknown code or a dropped transport is a plain loss.
  @doc "What a client must do after a close."
  @spec reaction(reason() | :lost) :: reaction()
  def reaction(:unsupported_version), do: :stop
  def reaction(:fenced), do: :fence
  def reaction(reason) when reason in [:refused, :reauthenticate], do: :reload_credential
  def reaction(:draining), do: :reconnect_now
  def reaction(_reason), do: :reconnect
end
