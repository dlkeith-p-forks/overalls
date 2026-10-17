defmodule Marshall.SSH.AuthorityTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures, only: [user: 0]
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.SSH
  alias Marshall.SSH.{Approval, Session, Token}

  setup do
    {token, _} = Token.issue(:gateway)

    {:ok, gateway} =
      SSH.configure_gateway(%{name: "porsche", token: token}, actor: SystemActor.compute())

    %{gateway_token: token, gateway: gateway, user: user()}
  end

  test "an attested unknown key requires explicit single-use approval", c do
    {:ok, pending} = open(c, public_key(<<1::256>>))
    assert pending.status == "pending"
    token = String.replace_prefix(pending.approval_path, "/ssh/approve/", "")
    assert {:ok, %{status: "pending"}} = status(c, pending)

    assert {:ok, %{fingerprint: fingerprint}} =
             SSH.inspect_approval(%{token: token}, actor: c.user)

    assert fingerprint == pending.fingerprint
    assert {:ok, %{status: "pending"}} = status(c, pending)
    assert {:error, _} = SSH.approve_key(%{token: token}, actor: nil)

    assert {:ok, %{approved: true}} =
             SSH.approve_key(%{token: token, label: "Laptop"}, actor: c.user)

    assert {:ok, %{status: "authenticated", user: %{id: id}}} = status(c, pending)
    assert id == c.user.id
    assert {:error, _} = SSH.approve_key(%{token: token}, actor: c.user)
    assert {:error, _} = SSH.approve_key(%{token: token}, actor: user())
    assert {:ok, [%{label: "Laptop"}]} = SSH.list_keys(%{}, actor: c.user)
    [session] = Ledger.read!(Session, id: pending.session_id)
    refute session.token_hash == pending.session_token
    assert session.token_hash == :crypto.hash(:sha256, pending.session_token)
  end

  property "removal and re-addition never restore a previous connection", c do
    check all(bytes <- binary(length: 32), max_runs: 20) do
      text = public_key(bytes)
      assert {:ok, key} = SSH.add_key(%{public_key: text}, actor: c.user)
      assert {:ok, first} = open(c, text)
      assert first.status == "authenticated"
      assert {:ok, _} = SSH.remove_key(%{id: key.id}, actor: c.user)
      assert {:error, _} = status(c, first)
      assert {:ok, replacement} = SSH.add_key(%{public_key: text}, actor: c.user)
      assert {:error, _} = status(c, first)
      assert {:ok, second} = open(c, text)
      assert {:ok, %{status: "authenticated"}} = status(c, second)

      assert {:ok, %{closed: true}} =
               SSH.close_session(request(c, second), actor: SystemActor.compute())

      assert {:ok, %{closed: true}} =
               SSH.close_session(request(c, second), actor: SystemActor.compute())

      assert {:error, _} = status(c, second)
      assert {:ok, _} = SSH.remove_key(%{id: replacement.id}, actor: c.user)
    end
  end

  test "gateway rotation and another gateway cannot inherit a session", c do
    {:ok, pending} = open(c, public_key(<<2::256>>))
    {other_token, _} = Token.issue(:gateway)

    {:ok, _} =
      SSH.configure_gateway(%{name: "other", token: other_token}, actor: SystemActor.compute())

    assert {:error, _} = status(%{c | gateway_token: other_token}, pending)
    {new_token, _} = Token.issue(:gateway)

    {:ok, rotated} =
      SSH.configure_gateway(%{name: "porsche", token: new_token}, actor: SystemActor.compute())

    assert rotated.generation == c.gateway.generation + 1
    assert {:error, _} = status(c, pending)
    assert {:error, _} = status(%{c | gateway_token: new_token}, pending)
    token = String.replace_prefix(pending.approval_path, "/ssh/approve/", "")
    assert {:error, _} = SSH.approve_key(%{token: token}, actor: c.user)
  end

  test "closed and expired connections cannot be approved", c do
    for mode <- [:closed, :expired] do
      {:ok, pending} = open(c, public_key(:crypto.strong_rand_bytes(32)))
      token = String.replace_prefix(pending.approval_path, "/ssh/approve/", "")

      if mode == :closed do
        assert {:ok, _} = SSH.close_session(request(c, pending), actor: SystemActor.compute())
      else
        [session] = Ledger.read!(Session, id: pending.session_id)
        Ledger.update!(session, :approve, %{expires_at: DateTime.add(Ledger.now(), -1)})
      end

      assert {:error, _} = SSH.approve_key(%{token: token}, actor: c.user)
      assert {:error, _} = status(c, pending)
    end

    assert {:ok, []} = SSH.list_keys(%{}, actor: c.user)
  end

  test "expiry of the approval itself is authoritative", c do
    {:ok, pending} = open(c, public_key(<<3::256>>))
    token = String.replace_prefix(pending.approval_path, "/ssh/approve/", "")
    [approval] = Ledger.read!(Approval, session_id: pending.session_id)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE ssh_approvals SET expires_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [Ecto.UUID.dump!(approval.id)],
      log: false
    )

    assert {:error, _} = SSH.approve_key(%{token: token}, actor: c.user)
    assert {:ok, %{status: "pending"}} = status(c, pending)
    assert {:ok, []} = SSH.list_keys(%{}, actor: c.user)
  end

  test "ordinary users cannot attest connections or configure gateways", c do
    {token, _} = Token.issue(:gateway)
    assert {:error, _} = SSH.configure_gateway(%{name: "forged", token: token}, actor: c.user)

    assert {:error, _} =
             SSH.open_session(
               %{gateway_token: c.gateway_token, public_key: public_key(<<1::256>>)},
               actor: c.user
             )

    assert {:error, _} = open(%{c | gateway_token: token}, public_key(<<1::256>>))
  end

  test "gateway session lifecycle emits structured events after commit", c do
    parent = self()
    key = public_key(<<31::256>>)

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      ExUnit.CaptureLog.capture_log(
        [metadata: [:event, :session_id, :key_id, :gateway_id]],
        fn ->
          {:ok, pending} = open(c, key)
          token = String.replace_prefix(pending.approval_path, "/ssh/approve/", "")

          assert {:ok, %{approved: true}} =
                   SSH.approve_key(%{token: token, label: "Laptop"}, actor: c.user)

          assert {:ok, %{closed: true}} =
                   SSH.close_session(request(c, pending), actor: SystemActor.compute())

          send(parent, {:session, pending.session_id})
        end
      )

    assert_receive {:session, session_id}
    assert logs =~ "SSH gateway session opened"
    assert logs =~ "SSH gateway key approved"
    assert logs =~ "SSH gateway session closed"
    assert logs =~ "session_id=" <> session_id
    assert logs =~ "gateway_id=" <> c.gateway.id
    assert logs =~ "key_id="
  end

  defp open(c, key),
    do:
      SSH.open_session(%{gateway_token: c.gateway_token, public_key: key},
        actor: SystemActor.compute()
      )

  defp status(c, session),
    do: SSH.session_status(request(c, session), actor: SystemActor.compute())

  defp request(c, session),
    do: %{gateway_token: c.gateway_token, session_token: session.session_token}

  defp public_key(bytes),
    do: "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, bytes::binary>>)
end
