defmodule Susan.OperatorTest do
  use Susan.DataCase, async: false
  import ExUnit.CaptureIO

  alias Susan.Audit.Log
  alias Susan.Operator
  alias Susan.Relay.{InstallIdentity, KeyDenial}

  @moduletag :tmp_dir

  test "audit tail, export and verify are themselves audited", %{tmp_dir: dir} do
    {:ok, _} = Log.append(:key_issued, :ok, %{provider: :apns})
    assert capture_io(fn -> Operator.audit_tail(5) end) =~ ~s("action":"key_issued")
    path = Path.join(dir, "audit.jsonl")
    assert capture_io(fn -> Operator.audit_export(path) end) =~ "exported 2"
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert capture_io(fn -> Operator.audit_export(path) end) =~ "refused"
    assert capture_io(fn -> Operator.audit_verify() end) =~ "intact"
    assert Enum.map(Log.read(), & &1.reason) == [nil, :audit_read, :audit_export, :audit_verify]
  end

  test "deny-listing and blocking are audited and enforced" do
    key_id = Susan.PushKey.uuid()
    assert capture_io(fn -> Operator.denylist_key(key_id, :compromised) end) =~ "denied"
    assert %KeyDenial{reason: :compromised} = KeyDenial.denied!(key_id)
    assert capture_io(fn -> Operator.denylist_key("nope") end) =~ "refused"

    fingerprint = String.duplicate("b", 64)
    {:ok, _} = InstallIdentity.first_seen(fingerprint)
    assert capture_io(fn -> Operator.block_install(fingerprint) end) =~ "blocked"
    assert %{state: :blocked} = InstallIdentity.by_fingerprint!(fingerprint)
    assert capture_io(fn -> Operator.unblock_install(fingerprint) end) =~ "unblocked"
    assert %{state: :trusted} = InstallIdentity.by_fingerprint!(fingerprint)
    assert capture_io(fn -> Operator.block_install("zz") end) =~ "refused"

    assert Enum.map(Log.read(), & &1.action) == [:key_denylisted, :install_blocked, :admin]
  end
end
