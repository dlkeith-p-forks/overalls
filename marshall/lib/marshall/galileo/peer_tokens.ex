defmodule Marshall.Galileo.PeerTokens do
  @moduledoc "Opaque, digest-backed, one-use peer provenance tokens."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Galileo
  @prefix "galileo_peer_"
  @ttl_seconds 30
  @cleanup_batch_size 1_000

  # @cc [owner:ghuntley,label:security;concurrency] galileo-peer-token-one-use
  # Minting MUST persist only a SHA-256 digest bound to the source VM and
  # integration. Verification MUST atomically consume one unexpired row using
  # database time, yielding at most one winner across all Marshall nodes, and
  # MUST require that the integration and its user or team owner remain live.
  # Archived teams MUST refuse without consuming a pending token.
  @spec mint(binary(), binary(), binary()) :: binary()
  def mint(source_vm_id, integration_id, name) do
    cleanup_expired()
    token = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {:ok, _} =
      Galileo.issue_peer_token(
        %{
          digest: digest(token),
          source_vm_id: source_vm_id,
          integration_id: integration_id,
          integration_name: name,
          expires_at: DateTime.add(Marshall.Compute.Ledger.now(), @ttl_seconds, :second)
        },
        actor: SystemActor.compute()
      )

    token
  end

  @spec verify(term()) :: {:ok, map()} | {:error, :invalid_peer_token}
  def verify(@prefix <> encoded = token) when byte_size(encoded) == 43 do
    with {:ok, bytes} when byte_size(bytes) == 32 <- Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == encoded,
         %{rows: [[source_vm_id, integration_id, name, expires_at]]} <- consume(digest(token)) do
      {:ok,
       %{
         source_vm_id: source_vm_id,
         integration_id: integration_id,
         name: name,
         expires_at: expires_at
       }}
    else
      _ -> {:error, :invalid_peer_token}
    end
  end

  def verify(_), do: {:error, :invalid_peer_token}

  defp consume(digest) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      """
      DELETE FROM galileo_peer_tokens AS token
      USING galileo_integrations AS integration
      LEFT JOIN users AS owner ON owner.id = integration.owner_id
      LEFT JOIN teams AS team ON team.id = integration.team_id
      WHERE token.digest = $1
        AND token.expires_at > clock_timestamp()
        AND integration.id = token.integration_id
        AND integration.archived_at IS NULL
        AND (integration.owner_id IS NULL OR owner.deleted_at IS NULL)
        AND (integration.team_id IS NULL OR
             (team.id IS NOT NULL AND team.archived_at IS NULL))
      RETURNING token.source_vm_id::text, token.integration_id::text, token.integration_name,
                EXTRACT(EPOCH FROM token.expires_at)::bigint
      """,
      [digest],
      log: false
    )
  end

  # @cc [owner:ghuntley,label:persistence] galileo-peer-token-retention
  # Minting MUST reclaim a bounded batch of expired tokens so abandoned tokens
  # cannot grow the authority table without bound while traffic continues.
  defp cleanup_expired do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      """
      DELETE FROM galileo_peer_tokens
      WHERE id IN (
        SELECT id
        FROM galileo_peer_tokens
        WHERE expires_at <= clock_timestamp()
        ORDER BY expires_at
        LIMIT $1
      )
      """,
      [@cleanup_batch_size],
      log: false
    )
  end

  defp digest(token), do: :crypto.hash(:sha256, token)
end
