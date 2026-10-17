defmodule Marshall.CommittedMailFixture do
  @moduledoc "Committed outbox fixture with captured cleanup identity and redacted observations."
  alias Marshall.Accounts.{AuthEmail, AuthEmails, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Repo

  @type fixture :: %{
          id: String.t(),
          jti: String.t(),
          jobs: [pos_integer()],
          token_digest: binary()
        }
  @type snapshot :: %{status: :pending | :delivered | :expired, ciphertext_digest: binary() | nil}
  @type invalidation :: :removed | :expired
  @type token_state :: :valid | :expired | :absent

  # @cc [owner:ghuntley,label:verification;security] committed-mail-captured-identity
  # Setup MUST capture the exact delivery ID, stored token JTI and created job
  # IDs before SMTP delivery can erase the payload. Observations MUST expose
  # only status and digests, never plaintext tokens or encrypted payload bytes.
  @spec enqueue() :: fixture()
  def enqueue do
    {:ok, fixture} = Repo.transaction(&insert/0)
    fixture
  end

  @spec insert() :: fixture()
  defp insert do
    email = "committed-smtp-#{Ash.UUID.generate()}@example.test"
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

    {:ok, %{"jti" => jti}, User} = AshAuthentication.Jwt.verify(token, User)
    :ok = AuthEmails.enqueue(email, token)
    fingerprint = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    [record] = Ledger.read!(AuthEmail, token_fingerprint: fingerprint)

    %{rows: jobs} =
      query("SELECT id FROM oban_jobs WHERE args->'primary_key'->>'id'=$1 ORDER BY id", [
        record.id
      ])

    %{
      id: record.id,
      jti: jti,
      jobs: Enum.map(jobs, fn [id] -> id end),
      token_digest: :crypto.hash(:sha256, token)
    }
  end

  @spec deliver(String.t()) ::
          {:ok, :delivered | :expired | :pending} | {:error, :delivery_failed}
  def deliver(id) do
    record = Ash.get!(AuthEmail, id, actor: SystemActor.compute())

    case record
         |> Ash.Changeset.for_update(:deliver, %{}, actor: SystemActor.compute())
         |> Ash.update() do
      {:ok, record} -> {:ok, record.status}
      {:error, _} -> {:error, :delivery_failed}
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] mail-post-ack-uncommitted-barrier
  # The gate MUST run after the real deliver action updates delivered/nil state
  # but while its transaction is still open. Observations MUST expose only
  # closed booleans and a test nonce, never the record or credential payload.
  @spec deliver_before_commit(String.t(), reference()) ::
          {:ok, :delivered | :expired | :pending} | {:error, :delivery_failed}
  def deliver_before_commit(id, fence) do
    gate = :ets.new(:mail_post_ack_gate, [:named_table, :public, :set])
    record = Ash.get!(AuthEmail, id, actor: SystemActor.compute())

    changeset =
      record
      |> Ash.Changeset.for_update(:deliver, %{}, actor: SystemActor.compute())
      |> Ash.Changeset.after_action(fn _changeset, delivered ->
        true =
          :ets.insert(gate, {
            fence,
            Repo.in_transaction?(),
            delivered.status == :delivered,
            is_nil(delivered.encrypted_payload)
          })

        receive do
          {:release_mail_commit, ^fence} -> {:ok, delivered}
        after
          15_000 -> {:error, :mail_commit_gate_timeout}
        end
      end)

    case Ash.update(changeset) do
      {:ok, delivered} -> {:ok, delivered.status}
      {:error, _} -> {:error, :delivery_failed}
    end
  end

  # @cc [owner:ghuntley,label:verification;security] mail-commit-gate-closed-observation
  # The peer-local gate MUST expose only nonce-correlated booleans through RPC.
  # Its table MUST be owned by the delivery process and disappear with that owner.
  @spec commit_gate(reference()) :: :waiting | {:entered, boolean(), boolean(), boolean()}
  def commit_gate(fence) do
    case :ets.whereis(:mail_post_ack_gate) do
      :undefined ->
        :waiting

      gate ->
        case :ets.lookup(gate, fence) do
          [{^fence, transaction?, delivered?, erased?}]
          when is_boolean(transaction?) and is_boolean(delivered?) and is_boolean(erased?) ->
            {:entered, transaction?, delivered?, erased?}

          [] ->
            :waiting
        end
    end
  end

  @spec snapshot(String.t()) :: snapshot()
  def snapshot(id) do
    record = Ash.get!(AuthEmail, id, actor: SystemActor.compute())
    digest = if record.encrypted_payload, do: :crypto.hash(:sha256, record.encrypted_payload)
    %{status: record.status, ciphertext_digest: digest}
  end

  # @cc [owner:ghuntley,label:verification;security] mail-waiting-token-authority
  # Invalidation MUST affect only the captured magic-link JTI and commit before
  # releasing the competing SMTP attempt. Token-state observations MUST read
  # stored authority independently and return no token or recipient contents.
  @spec invalidate_token(String.t(), invalidation()) :: :ok
  def invalidate_token(jti, kind) do
    if Repo.in_transaction?(), do: raise("Mail invalidation requires a committed connection")

    sql =
      case kind do
        :removed ->
          "DELETE FROM tokens WHERE jti=$1 AND purpose='magic_link'"

        :expired ->
          "UPDATE tokens SET expires_at=(clock_timestamp() AT TIME ZONE 'UTC')-interval '1 second' WHERE jti=$1 AND purpose='magic_link'"
      end

    %{num_rows: 1} = query(sql, [jti])
    :ok
  end

  @spec token_state(String.t()) :: token_state()
  def token_state(jti) do
    case query(
           "SELECT expires_at > (statement_timestamp() AT TIME ZONE 'UTC') FROM tokens WHERE jti=$1 AND purpose='magic_link'",
           [jti]
         ).rows do
      [[true]] -> :valid
      [[false]] -> :expired
      [] -> :absent
      _ -> raise "Unexpected stored magic-link authority shape"
    end
  end

  @spec outbox_time_valid?(String.t()) :: boolean()
  def outbox_time_valid?(id) do
    record = Ash.get!(AuthEmail, id, actor: SystemActor.compute())
    DateTime.compare(record.expires_at, Ledger.now()) == :gt
  end

  # @cc [owner:ghuntley,label:verification] committed-mail-exact-cleanup
  # Cleanup MUST delete only captured job IDs, delivery ID and magic-link JTI.
  # Callers MUST drain operations or observe peer termination before deletion;
  # Only those captured jobs' trigger-created history may be removed; unrelated
  # rows and unrelated job history MUST remain intact.
  @spec cleanup(fixture()) :: :ok
  def cleanup(fixture) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        Marshall.CommittedFixtureCleanup.jobs!("id=ANY($1::bigint[])", [fixture.jobs])
        query("DELETE FROM account_auth_emails WHERE id=$1", [Ecto.UUID.dump!(fixture.id)])
        query("DELETE FROM tokens WHERE jti=$1 AND purpose='magic_link'", [fixture.jti])
        :ok
      end)

    :ok
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  def query(sql, params \\ []), do: Repo.query!(sql, params, log: false)
end
