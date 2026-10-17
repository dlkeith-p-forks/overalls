defmodule Marshall.SSH.AuthorityModelTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.SSH
  alias Marshall.SSH.{Session, Token}

  property "generated approval, expiry, rotation and key histories never resurrect authority" do
    owner = Marshall.ComputeFixtures.user()

    check all(
            actions <-
              list_of(member_of([:approve, :revoke_key, :add_key, :close, :expire, :rotate]),
                min_length: 1,
                max_length: 16
              ),
            max_runs: 25
          ) do
      {gateway_token, _} = Token.issue(:gateway)

      {:ok, _} =
        SSH.configure_gateway(%{name: "model", token: gateway_token},
          actor: SystemActor.compute()
        )

      text =
        "ssh-ed25519 " <>
          Base.encode64(<<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>)

      {:ok, pending} =
        SSH.open_session(%{gateway_token: gateway_token, public_key: text},
          actor: SystemActor.compute()
        )

      approval = String.replace_prefix(pending.approval_path, "/ssh/approve/", "")
      context = %{owner: owner, public_key: text, approval: approval, session: pending}

      initial = %{
        gateway_token: gateway_token,
        gateway_valid: true,
        live: true,
        approved: false,
        key_live: false,
        key: nil
      }

      model =
        Enum.reduce(actions, initial, fn action, model ->
          next = step(action, model, context)

          result =
            SSH.session_status(
              %{gateway_token: next.gateway_token, session_token: pending.session_token},
              actor: SystemActor.compute()
            )

          cond do
            not next.gateway_valid or not next.live -> assert match?({:error, _}, result)
            not next.approved -> assert {:ok, %{status: "pending"}} = result
            next.key_live -> assert {:ok, %{status: "authenticated"}} = result
            true -> assert match?({:error, _}, result)
          end

          next
        end)

      if model.key, do: SSH.remove_key(%{id: model.key.id}, actor: owner)
    end
  end

  defp step(:approve, model, c) do
    result = SSH.approve_key(%{token: c.approval}, actor: c.owner)

    if model.gateway_valid and model.live and not model.approved do
      assert {:ok, %{approved: true}} = result
      {:ok, keys} = SSH.list_keys(%{}, actor: c.owner)
      {:ok, parsed} = OverallsProtocol.SSHKey.parse(c.public_key)
      key = Enum.find(keys, &(&1.fingerprint == parsed.fingerprint))
      assert key
      %{model | approved: true, key_live: true, key: key}
    else
      assert {:error, _} = result
      model
    end
  end

  defp step(:add_key, model, c) do
    assert {:ok, key} = SSH.add_key(%{public_key: c.public_key}, actor: c.owner)
    %{model | key: key}
  end

  defp step(:revoke_key, %{key: nil} = model, _), do: model

  defp step(:revoke_key, model, c) do
    assert {:ok, _} = SSH.remove_key(%{id: model.key.id}, actor: c.owner)
    %{model | key: nil, key_live: false}
  end

  defp step(:close, model, c) do
    result =
      SSH.close_session(
        %{gateway_token: model.gateway_token, session_token: c.session.session_token},
        actor: SystemActor.compute()
      )

    if model.gateway_valid do
      assert {:ok, %{closed: true}} = result
      %{model | live: false}
    else
      assert {:error, _} = result
      model
    end
  end

  defp step(:expire, model, c) do
    [session] = Ledger.read!(Session, id: c.session.session_id)
    Ledger.update!(session, :approve, %{expires_at: DateTime.add(Ledger.now(), -1)})
    %{model | live: false}
  end

  defp step(:rotate, model, _) do
    {token, _} = Token.issue(:gateway)

    assert {:ok, _} =
             SSH.configure_gateway(%{name: "model", token: token}, actor: SystemActor.compute())

    %{model | gateway_token: token, gateway_valid: false}
  end
end
