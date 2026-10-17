defmodule Marshall.ReadRevocationFixture do
  @moduledoc "Per-replica protected-read decisions and durable session-state observation."

  alias Marshall.Accounts.{Login, Security, User}
  alias Marshall.Authorization.Cedar
  alias Marshall.Repo

  @type decision :: :allow | :refuse
  @type invalidation_kind :: :revoke_sessions | :token_revoke | :expire

  # @cc [owner:ghuntley,label:verification] read-revocation-hook-decisions
  # Browser read decisions MUST mirror the exact production admission checks:
  # LiveUserAuth.fresh_login/1 (handbook and machines required-login routes),
  # LiveAdminAuth.check/1 (Control room) and InferenceExportController's current
  # Login.verify/2. A decision MUST be exactly :allow or :refuse; raising reads
  # MUST NOT be reported as a closed refusal.
  @spec browser_read(User.t()) :: decision()
  def browser_read(%User{} = reader) do
    with {:ok, _} <- Login.present(Security.jti(reader), reader.id),
         %User{deleted_at: nil} <- Security.current(reader.id) do
      :allow
    else
      _ -> :refuse
    end
  end

  @spec control_room_read(User.t()) :: decision()
  def control_room_read(%User{} = reader) do
    with true <- Cedar.allowed?(reader, "admin_read", Cedar.entity("ControlPlane", "marshall")),
         %User{deleted_at: nil} <- Security.current(reader.id) do
      :allow
    else
      _ -> :refuse
    end
  end

  @spec export_read(User.t(), String.t()) :: decision()
  def export_read(%User{} = reader, token) when is_binary(token) do
    case Login.verify(token, reader) do
      {:ok, _, _} -> :allow
      :error -> :refuse
    end
  end

  @spec projection_read(User.t()) :: decision()
  def projection_read(%User{} = reader) do
    case User
         |> Ash.ActionInput.for_action(:list_admin_users, %{}, actor: reader)
         |> Ash.run_action() do
      {:ok, _} -> :allow
      {:error, _} -> :refuse
    end
  end

  # @cc [owner:ghuntley,label:verification] read-revocation-durable-oracle
  # Durable session state MUST be observed by raw SQL against the executing
  # replica's database connection, reporting purpose, database-time expiry and
  # presence only. The oracle MUST NOT call Login, Security or Cedar, so a
  # SUT-side cache or invalidation predicate cannot supply its own evidence.
  @spec durable_login_state(String.t()) :: :absent | %{purpose: String.t(), expired: boolean()}
  def durable_login_state(jti) when is_binary(jti) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT purpose, expires_at <= clock_timestamp() FROM tokens WHERE jti = $1",
        [jti],
        log: false
      )

    case rows do
      [] -> :absent
      [[purpose, expired]] -> %{purpose: purpose, expired: expired}
    end
  end

  # @cc [owner:ghuntley,label:verification] read-revocation-invalidations
  # Each invalidation MUST change durable authority through a real path: the
  # administrative account-locked session revocation, the stored-token
  # revocation action, or database-time expiry. Fixture invalidations MUST leave
  # no row state a real operation could not produce.
  @spec invalidate(invalidation_kind(), User.t(), String.t(), User.t()) ::
          :ok | {:ok, term()} | {:error, term()}
  def invalidate(:revoke_sessions, admin, _token, reader),
    do: Marshall.RememberedLoginFixture.revoke(admin, reader.id)

  def invalidate(:token_revoke, _admin, token, _reader),
    do: AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)

  def invalidate(:expire, _admin, _token, reader) do
    %{num_rows: 1} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE tokens SET expires_at = clock_timestamp() - interval '1 second' WHERE jti = $1 AND purpose = 'user'",
        [Security.jti(reader)],
        log: false
      )

    :ok
  end

  # @cc [owner:ghuntley,label:verification] read-revocation-expected-durable
  # The model MUST derive the durable consequence of each invalidation kind;
  # assertion failures MUST distinguish durable-state mismatches from read
  # outcome mismatches.
  @spec expected_durable(invalidation_kind()) :: %{purpose: String.t(), expired: boolean()}
  def expected_durable(kind) when kind in [:revoke_sessions, :token_revoke],
    do: %{purpose: "revocation", expired: false}

  def expected_durable(:expire), do: %{purpose: "user", expired: true}
end
