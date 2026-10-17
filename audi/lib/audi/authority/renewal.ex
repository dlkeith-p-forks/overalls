defmodule Audi.Authority.Renewal do
  @moduledoc """
  Classifies a failed stream-lease renewal (ADR-0140: slowness is never
  evidence).

  A definite refusal from Marshall (or a changed binding) revokes the stream at
  once. An inconclusive failure (transport error, a non-2xx response, a grant
  that arrived after its own deadline) only means the renewal did not complete:
  the stream keeps its current lease, retries, and is still ended by its
  guard's deadline if renewal never recovers. Revocation latency stays bounded
  by the unchanged lease ceiling.
  """

  @inconclusive [:transport_error, :http_error, :expired_response]

  # @cc [owner:ghuntley,label:security;recovery] audi-renewal-inconclusive-retry
  # Only transport errors, non-2xx responses and late grants are inconclusive.
  # Every other failure, including authentication/authorization denials, an
  # invalid message, a binding mismatch or a changed identity, MUST revoke.
  # An inconclusive failure MUST NOT extend the current lease.
  @spec inconclusive?(term()) :: boolean()
  def inconclusive?({:error, reason}), do: reason in @inconclusive
  def inconclusive?(_), do: false

  @doc "Retry delay after an inconclusive failure, bounded by the lease deadline."
  @spec retry_after(integer(), integer()) :: pos_integer()
  def retry_after(expires_at, now), do: max(min(250, div(expires_at - now, 2)), 1)
end
