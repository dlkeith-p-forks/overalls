defmodule Marshall.Compute.HostLiveness do
  @moduledoc """
  One classification of a provisioner host's liveness for every consumer
  (ADR-0140 host tier).

  Marshall runs on several nodes, so liveness is derived from the shared host
  row rather than per-node state: the current connection session and the
  latest accepted report's `reported_at` (the host's sample time).

  * `:disconnected` - no current connection session.
  * `:live`         - a report no older than `capacity_freshness_ms`.
  * `:late`         - an older report within `host_authority_ms`.
  * `:lost`         - no report, an older report, or a future-dated one.

  Capacity decisions (admission, placement, resize, relocation, drains,
  evacuation) need current numbers and require `:live`. Authority decisions
  (terminal, ingress, DNS publication, inference, Galileo, SSH access) only need
  a host that is still there, so a late report keeps them working: slowness is
  not evidence of loss. A new or reset session, credential change or retirement
  ends authority immediately through the session and host fields consumers
  already check.
  """

  @type state :: :disconnected | :live | :late | :lost

  # @cc [owner:ghuntley,label:capacity;security] host-liveness-single-classification
  # state/3 MUST be the only liveness classification. It is :disconnected
  # without a session; :lost for a missing or future-dated report or an age
  # beyond host_authority_ms; :live within capacity_freshness_ms; otherwise
  # :late. capacity_fresh?/2 MUST require :live; authority?/3 MUST accept only
  # :live or :late. The capacity window MUST NOT exceed the authority window.
  @spec state(String.t() | nil, DateTime.t() | nil, DateTime.t()) :: state()
  def state(session, _reported_at, _now) when not is_binary(session), do: :disconnected
  def state(_session, nil, _now), do: :lost

  def state(_session, reported_at, now) do
    age = DateTime.diff(now, reported_at, :millisecond)

    cond do
      age < 0 -> :lost
      age <= capacity_ms() -> :live
      age <= authority_ms() -> :late
      true -> :lost
    end
  end

  @doc "Whether a report is current enough for capacity decisions."
  @spec capacity_fresh?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def capacity_fresh?(reported_at, now), do: state("capacity", reported_at, now) == :live

  @doc "Whether a connected host is alive enough to keep authorizing work."
  @spec authority?(String.t() | nil, DateTime.t() | nil, DateTime.t()) :: boolean()
  def authority?(session, reported_at, now),
    do: state(session, reported_at, now) in [:live, :late]

  @doc "Milliseconds a report keeps capacity decisions current."
  @spec capacity_ms() :: pos_integer()
  def capacity_ms, do: Application.fetch_env!(:marshall, :capacity_freshness_ms)

  @doc "Milliseconds a report keeps host authority (the liveness backstop)."
  @spec authority_ms() :: pos_integer()
  def authority_ms, do: Application.fetch_env!(:marshall, :host_authority_ms)

  @doc "Milliseconds a busy pool entry may extend the last real measurement's freshness."
  @spec busy_grace_ms() :: pos_integer()
  def busy_grace_ms, do: Application.fetch_env!(:marshall, :pool_busy_grace_ms)

  # @cc [owner:ghuntley,label:capacity] busy-grace-within-authority
  # The busy grace plus the capacity window MUST NOT exceed the authority
  # window: an extended measurement can never outlive the host's authority.
  @spec check_windows!() :: :ok
  def check_windows! do
    if capacity_ms() > authority_ms() or busy_grace_ms() + capacity_ms() > authority_ms(),
      do: raise(ArgumentError, "capacity freshness and busy grace exceed host authority")

    :ok
  end
end
