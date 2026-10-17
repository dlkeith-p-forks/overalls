defmodule Audi.Authority.Lease do
  @moduledoc "Local monotonic interpretation of a trusted control-plane grant."
  @enforce_keys [:binding, :requested_at, :expires_at]
  defstruct [:binding, :requested_at, :expires_at]
  @type t :: %__MODULE__{binding: map(), requested_at: integer(), expires_at: integer()}

  # @cc [owner:ghuntley,label:security] audi-grant-request-deadline
  # A trusted grant MUST expire at requested_at + ttl, where ttl is positive
  # and at most thirty seconds; receipt MUST NOT restart its lifetime. Callers
  # MUST pass authenticated control replies. This generic limit permits ordinary
  # web, SSH and editor grants up to thirty seconds. Marshall's nested issuer
  # MUST limit nested grants to five seconds and the publication's remaining
  # lifetime; Audi's nested decoder and this lease accept the generic 30-second
  # envelope. All timestamps MUST use this node's monotonic millisecond
  # clock.
  @spec new(map(), integer(), integer(), integer()) :: {:ok, t()} | {:error, :invalid_grant}
  def new(binding, requested_at, ttl, now)
      when is_map(binding) and map_size(binding) > 0 and is_integer(requested_at) and
             is_integer(ttl) and ttl in 1..30_000 and is_integer(now) and requested_at <= now and
             requested_at + ttl > now do
    {:ok,
     %__MODULE__{binding: binding, requested_at: requested_at, expires_at: requested_at + ttl}}
  end

  def new(_, _, _, _), do: {:error, :invalid_grant}

  @spec active?(t(), integer()) :: boolean()
  def active?(lease, now), do: now < lease.expires_at

  # @cc [owner:ghuntley,label:security] audi-grant-no-resurrection
  # Renewal MUST preserve the complete immutable session/placement binding.
  # Expired leases MUST never revive, even if the expiry timer has not run.
  # Reordered replies MUST NOT replace a newer request's grant.
  @spec renew(t(), map(), integer(), integer(), integer()) ::
          {:ok, t()} | {:error, :expired | :binding_changed | :stale | :invalid_grant}
  def renew(lease, binding, requested_at, ttl, now) do
    cond do
      not active?(lease, now) -> {:error, :expired}
      binding != lease.binding -> {:error, :binding_changed}
      is_integer(requested_at) and requested_at <= lease.requested_at -> {:error, :stale}
      true -> new(binding, requested_at, ttl, now)
    end
  end
end
