defmodule Marshall.SSH.RetentionTest do
  use Marshall.DataCase, async: false
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.SSH
  alias Marshall.SSH.{Approval, Session, Token}

  test "real AshOban cleanup continues bounded batches and preserves current sessions and keys" do
    {token, _} = Token.issue(:gateway)

    {:ok, gateway} =
      SSH.configure_gateway(%{name: "retention", token: token}, actor: SystemActor.compute())

    owner = Marshall.ComputeFixtures.user()
    text = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 71::256>>)
    {:ok, key} = SSH.add_key(%{public_key: text}, actor: owner)

    {:ok, live} =
      SSH.open_session(%{gateway_token: token, public_key: text}, actor: SystemActor.compute())

    cutoff = DateTime.add(Ledger.now(), -8 * 86_400)

    expired =
      for _ <- 1..501 do
        {_, hash} = Token.issue(:session)

        Ledger.create!(Session, :record, %{
          gateway_id: gateway.id,
          gateway_generation: gateway.generation,
          token_hash: hash,
          expires_at: cutoff
        })
      end

    {_, hash} = Token.issue(:approval)

    Ledger.create!(Approval, :record, %{
      token_hash: hash,
      session_id: hd(expired).id,
      public_key: text,
      fingerprint: key.fingerprint,
      expires_at: cutoff
    })

    AshOban.schedule(Session, :prune)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    assert length(Ledger.read!(Session)) == 2
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    assert [%{id: id}] = Ledger.read!(Session)
    assert id == live.session_id
    assert [] = Ledger.read!(Approval)
    assert {:ok, [^key]} = SSH.list_keys(%{}, actor: owner)

    assert {:ok, %{status: "authenticated"}} =
             SSH.session_status(%{gateway_token: token, session_token: live.session_token},
               actor: SystemActor.compute()
             )
  end
end
