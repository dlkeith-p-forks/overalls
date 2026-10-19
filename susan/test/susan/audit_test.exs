defmodule Susan.AuditTest do
  use Susan.DataCase, async: false

  alias Susan.Audit.{Chain, Log}
  alias Susan.Repo

  test "appends chain from genesis and verify detects edits, removals and reordering" do
    {:ok, a} =
      Log.append(:key_issued, :ok, %{key_id: Susan.PushKey.uuid(), provider: :apns, keyring_id: 1})

    {:ok, b} =
      Log.append(:poke_rejected, :refused, %{
        reason: :replayed,
        install_fingerprint: String.duplicate("a", 64)
      })

    {:ok, c} = Log.append(:admin, :ok, %{reason: :audit_read})
    assert a.prev_digest == Chain.genesis()
    assert b.prev_digest == a.digest and c.prev_digest == b.digest
    assert :ok = Log.verify()
    assert :ok = Chain.verify([b, c])
    assert {:error, {:broken_at, 1}} = Chain.verify([a, c])
    assert {:error, {:broken_at, 1}} = Chain.verify([a, %{b | reason: :stale}, c])
    assert {:error, {:broken_at, 1}} = Chain.verify([b, a])
  end

  test "the database refuses UPDATE, DELETE and TRUNCATE outside the retention prune" do
    {:ok, entry} = Log.append(:admin, :ok, %{reason: :audit_verify})

    for statement <- [
          "UPDATE audit_entries SET outcome = 'failed'",
          "DELETE FROM audit_entries",
          "TRUNCATE audit_entries"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               attempt([statement])
    end

    # Even the prune guard cannot delete a young row.
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             attempt([
               "SELECT set_config('susan.audit_prune', 'on', true)",
               "DELETE FROM audit_entries WHERE seq = #{entry.seq}"
             ])

    assert [_] = Log.read()
  end

  test "the prune removes only expired rows and audits itself in the same transaction" do
    {:ok, old} = Log.append(:key_issued, :ok, %{provider: :fcm})
    {:ok, recent} = Log.append(:admin, :ok, %{reason: :audit_read})
    backdate(old.seq, 91)

    assert {:ok, 1} = Log.prune()
    assert [%{seq: seq}, %{action: :prune, count: 1, reason: :retention}] = Log.read()
    assert seq == recent.seq
    assert {:ok, 0} = Log.prune()
  end

  test "export lines carry only audit fields" do
    {:ok, _} =
      Log.append(:provider_sent, :ok, %{provider: :apns, delivery_id: Susan.PushKey.uuid()})

    [line] = Log.export_lines(Log.read())

    assert line |> JSON.decode!() |> Map.keys() |> Enum.sort() ==
             Enum.sort(
               ~w(seq prev_digest digest action reason install_fingerprint key_id provider outcome delivery_id keyring_id count occurred_at)
             )
  end

  # Backdating needs to bypass the append-only trigger, as a fixture only.
  defp backdate(seq, days) do
    Repo.query!("ALTER TABLE audit_entries DISABLE TRIGGER audit_entries_append_only", [])

    Repo.query!(
      "UPDATE audit_entries SET occurred_at = occurred_at - make_interval(days => $1) WHERE seq = $2",
      [days, seq]
    )

    Repo.query!("ALTER TABLE audit_entries ENABLE TRIGGER audit_entries_append_only", [])
  end

  defp attempt(statements) do
    Repo.transaction(fn ->
      Enum.each(statements, fn statement ->
        case Repo.query(statement, []) do
          {:ok, _} -> :ok
          {:error, error} -> Repo.rollback(error)
        end
      end)
    end)
  end
end
