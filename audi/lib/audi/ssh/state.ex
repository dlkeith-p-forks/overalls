defmodule Audi.SSH.State do
  @moduledoc "Pure SSH channel lifecycle; diagnostics never acquire stream authority."
  @type t :: :awaiting | :diagnostic | :opening | :relaying | :closed
  @type event :: :pty | :shell | :exec | :opened | :close | :other
  @type effect :: :acknowledge | :guide | :authorize | :relay | :close

  # @cc [owner:ghuntley,label:security] audi-diagnostic-no-stream
  # Only an exec from awaiting MAY enter opening. Diagnostic and closed states
  # MUST never enter opening or relaying, regardless of subsequent requests.
  @spec step(t(), event()) :: {t(), effect()}
  def step(:awaiting, :pty), do: {:diagnostic, :acknowledge}
  def step(state, :shell) when state in [:awaiting, :diagnostic], do: {:diagnostic, :guide}
  def step(:diagnostic, :exec), do: {:diagnostic, :guide}
  def step(:awaiting, :exec), do: {:opening, :authorize}
  def step(:opening, :opened), do: {:relaying, :relay}
  def step(_, _), do: {:closed, :close}
end
