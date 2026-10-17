defmodule Marshall.Terminal.ViewerAuthority do
  @moduledoc """
  The attached viewer's authority recheck decision (ADR-0140: slowness is
  never evidence).

  A conclusive refusal closes the viewer at once. A recheck is inconclusive
  only when the database itself cannot answer; the last confirmed authority
  then survives for at most `backstop_ms/0`, measured from the first
  inconclusive recheck, after which the viewer closes as
  `:authority_unconfirmed`. Any conclusive success clears the episode.
  """

  @backstop_ms 30_000

  @type result :: :ok | {:error, atom()} | :inconclusive
  @type since :: integer() | nil

  @spec backstop_ms() :: pos_integer()
  def backstop_ms, do: @backstop_ms

  # @cc [owner:ghuntley,label:security;recovery] viewer-authority-inconclusive-backstop
  # A conclusive refusal MUST close immediately and a success MUST clear the
  # unconfirmed episode. An inconclusive recheck MUST NOT close the viewer
  # before the backstop and MUST close it once the backstop has elapsed since
  # the episode began; it never extends an episode already under way.
  @doc "Steps the unconfirmed-since marker; returns the new marker or a refusal."
  @spec step(since(), result(), integer()) :: {:ok, since()} | {:refuse, atom()}
  def step(_since, :ok, _now), do: {:ok, nil}
  def step(_since, {:error, reason}, _now), do: {:refuse, reason}

  def step(since, :inconclusive, now) do
    started = since || now

    if now - started >= @backstop_ms,
      do: {:refuse, :authority_unconfirmed},
      else: {:ok, started}
  end
end
