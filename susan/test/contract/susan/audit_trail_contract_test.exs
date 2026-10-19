defmodule SusanAuditTrailContractTest do
  use Covenant.Case, component: "susan.audit_trail"

  alias Susan.Audit.{AuditEntry, Chain, Log}
  alias Susan.Relay.InstallIdentity
  alias Susan.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Susan.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  defp refused?(statement) do
    match?(
      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}},
      Repo.transaction(fn ->
        case Repo.query(statement, []) do
          {:ok, _} -> :ok
          {:error, error} -> Repo.rollback(error)
        end
      end)
    )
  end

  @tag obligation: "susan.audit_trail.I1"
  test "the database refuses mutation and the resource has no mutating action" do
    {:ok, _} = Log.append(:admin, :ok, %{reason: :audit_read})
    assert refused?("UPDATE audit_entries SET outcome = 'failed'")
    assert refused?("DELETE FROM audit_entries")
    assert refused?("TRUNCATE audit_entries")

    types =
      AuditEntry
      |> Ash.Resource.Info.actions()
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Enum.sort()

    assert types == [:create, :read]
  end

  @tag obligation: "susan.audit_trail.I2"
  test "the chain detects edits, removals and reordering" do
    {:ok, a} = Log.append(:key_issued, :ok, %{provider: :apns})
    {:ok, b} = Log.append(:key_issued, :ok, %{provider: :fcm})
    {:ok, c} = Log.append(:admin, :ok, %{reason: :audit_read})
    assert :ok = Chain.verify([a, b, c])
    assert {:error, _} = Chain.verify([a, c])
    assert {:error, _} = Chain.verify([a, %{b | provider: :apns}, c])
    assert {:error, _} = Chain.verify([b, a, c])
  end

  @tag obligation: "susan.audit_trail.I3"
  test "the prune deletes only expired rows and audits itself" do
    {:ok, old} = Log.append(:key_issued, :ok, %{provider: :apns})
    {:ok, _} = Log.append(:key_issued, :ok, %{provider: :fcm})
    Repo.query!("ALTER TABLE audit_entries DISABLE TRIGGER audit_entries_append_only", [])

    Repo.query!(
      "UPDATE audit_entries SET occurred_at = occurred_at - interval '100 days' WHERE seq = $1",
      [old.seq]
    )

    Repo.query!("ALTER TABLE audit_entries ENABLE TRIGGER audit_entries_append_only", [])
    assert {:ok, 1} = Log.prune()
    assert [%{provider: :fcm}, %{action: :prune, count: 1}] = Log.read()
  end

  @tag obligation: "susan.audit_trail.I4"
  test "install identities follow the documented lifecycle" do
    {:ok, identity} = InstallIdentity.first_seen(String.duplicate("e", 64))
    assert identity.state == :unknown
    {:ok, identity} = InstallIdentity.trust(identity)
    {:ok, identity} = InstallIdentity.rate_limit(identity)
    assert {:error, _} = InstallIdentity.trust(identity)
    {:ok, identity} = InstallIdentity.recover(identity)
    {:ok, identity} = InstallIdentity.block(identity)
    assert {:error, _} = InstallIdentity.recover(identity)
    assert {:error, _} = InstallIdentity.rate_limit(identity)
    assert {:ok, %{state: :trusted}} = InstallIdentity.unblock(identity)
  end

  @tag obligation: "susan.audit_trail.I5"
  test "relay tables have no column that could hold request content" do
    columns =
      Repo.query!(
        "SELECT table_name || '.' || column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name <> 'oban_jobs' AND table_name <> 'oban_peers' AND table_name <> 'schema_migrations'",
        []
      ).rows
      |> List.flatten()

    for forbidden <- ~w(token push_key ciphertext nonce deployment address ip route) do
      refute Enum.any?(columns, &(String.split(&1, ".") |> List.last() == forbidden)), forbidden
    end
  end
end
