defmodule Marshall.Accounts.CredentialHistoryTest do
  @moduledoc "Generated passkey lifecycle histories with an independent inventory oracle."
  use Marshall.DataCase, async: false
  import Hegel
  import Marshall.PasskeyFixture

  alias Marshall.Accounts.{Login, Passkey, PasskeyChallenge, Security}
  alias Marshall.Compute.Ledger
  alias Hegel.Gen, as: Gen

  @bogus "00000000-0000-0000-0000-000000000000"

  @typep credential :: %{label: String.t(), auth: map()}
  @typep model :: %{
           live: boolean(),
           elevated: boolean(),
           verified: boolean(),
           creds: %{String.t() => credential()},
           removed: [{String.t(), map()}],
           proving: String.t() | nil,
           mfa_enabled: boolean(),
           generation: non_neg_integer(),
           admin: boolean(),
           challenges: non_neg_integer()
         }

  # @cc [owner:ghuntley,label:verification] credential-history-oracle
  # Generated rename/remove/verify/lock/register/revoke histories MUST drive the
  # real security action against a model of login liveness, elevation, credential
  # labels, MFA generation and token presence. Every refused step MUST leave the
  # passkey, verification, token, challenge and audit rows byte-identical.
  @tag :hegel_case_sandbox
  property "current login, elevation and inventory govern credential self-service",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    admin = draw("admin", Gen.boolean())
    initial = draw("initial", Gen.integer(1..3))

    events =
      draw(
        "events",
        Gen.list_of(
          Gen.frequency([
            {4, Gen.tuple({Gen.constant(:rename), Gen.integer(0..999), label_gen()})},
            {3, Gen.tuple({Gen.constant(:remove), Gen.integer(0..999)})},
            {3, Gen.constant(:verify)},
            {2, Gen.tuple({Gen.constant(:verify_removed), Gen.integer(0..999)})},
            {1, Gen.constant(:lock)},
            {2, Gen.constant(:register)},
            {1, Gen.constant(:revoke_login)}
          ]),
          min_length: 1,
          max_length: 8
        )
      )

    history(admin, initial, events)
  end

  @spec label_gen() :: Gen.t(term())
  defp label_gen do
    Gen.frequency([
      {8, Gen.string(:alphanumeric, min_length: 1, max_length: 12)},
      {1, Gen.constant(String.duplicate("y", 80))},
      {2, Gen.member_of([nil, "", "   ", String.duplicate("x", 81)])}
    ])
  end

  @spec history(boolean(), pos_integer(), [tuple() | atom()]) :: :ok
  defp history(admin, initial, events) do
    user = user(admin)
    {actor, token} = login(user)
    first = register(actor)
    {:ok, %{verified: true}} = verify(actor, first)
    rest = for _ <- 2..initial//1, do: register(actor)
    authenticators = [first | rest]

    rows = Ledger.read!(Passkey, user_id: user.id)
    auth_by_credential = Map.new(authenticators, &{&1.id, &1})

    creds =
      Map.new(rows, &{&1.id, %{label: &1.label, auth: auth_by_credential[&1.credential_id]}})

    proving = Enum.find_value(rows, &(&1.credential_id == first.id && &1.id))

    model = %{
      live: true,
      elevated: true,
      verified: true,
      creds: creds,
      removed: [],
      proving: proving,
      mfa_enabled: true,
      generation: 0,
      admin: admin,
      challenges: initial + 1
    }

    Enum.reduce(events, model, fn event, current ->
      updated = step(event, actor, Security.jti(actor), token, current)
      assert_state(actor, updated)
      updated
    end)

    :ok
  end

  @spec step(tuple() | atom(), Marshall.Accounts.User.t(), String.t(), String.t(), model()) ::
          model()
  defp step({:rename, pick, label}, actor, _jti, _token, model) do
    target = credential_pick(model.creds, pick)
    valid = is_binary(label) and String.trim(label) != "" and String.length(label) <= 80

    allowed =
      model.live and model.elevated and Map.has_key?(model.creds, target) and valid

    before = snapshot()
    result = action(actor, :rename, %{"id" => target, "label" => label})
    assert match?({:ok, %{updated: true}}, result) == allowed
    unless allowed, do: assert(snapshot() == before)

    if allowed do
      %{model | creds: put_in(model.creds, [target, :label], String.trim(label))}
    else
      model
    end
  end

  defp step({:remove, pick}, actor, _jti, _token, model) do
    target = credential_pick(model.creds, pick)
    count = map_size(model.creds)

    allowed =
      model.live and model.elevated and Map.has_key?(model.creds, target) and
        not (model.admin and count == 1)

    before = snapshot()
    result = action(actor, :remove, %{"id" => target})
    assert match?({:ok, %{updated: true}}, result) == allowed
    unless allowed, do: assert(snapshot() == before)

    if allowed do
      creds = Map.delete(model.creds, target)
      removed = [{target, model.creds[target].auth} | model.removed]
      proving_removed = model.proving == target
      last = count == 1

      %{
        model
        | creds: creds,
          removed: removed,
          proving: if(proving_removed or last, do: nil, else: model.proving),
          elevated: if(proving_removed or last, do: false, else: model.elevated),
          verified: if(last or proving_removed, do: false, else: model.verified),
          mfa_enabled: not last,
          generation: if(last, do: model.generation + 1, else: model.generation),
          live: not last
      }
    else
      model
    end
  end

  defp step(:verify, actor, _jti, _token, model) do
    cond do
      model.live and model.creds != %{} and model.challenges < 10 ->
        [id | _] = sorted_ids(model.creds)
        {:ok, challenge} = action(actor, :begin_verify)

        assert {:ok, %{verified: true}} =
                 action(actor, :finish_verify, assertion(challenge, model.creds[id].auth))

        %{
          model
          | elevated: true,
            verified: true,
            proving: id,
            challenges: model.challenges + 1
        }

      true ->
        before = snapshot()
        assert {:error, _} = action(actor, :begin_verify)
        assert snapshot() == before
        model
    end
  end

  defp step({:verify_removed, pick}, actor, _jti, _token, model) do
    if model.live and model.creds != %{} and model.challenges < 10 do
      {_, auth} = Enum.at(model.removed, rem(pick, max(length(model.removed), 1)), {@bogus, nil})

      if auth do
        {:ok, challenge} = action(actor, :begin_verify)
        # A removed authenticator fails the ceremony but still consumes the slot.
        assert {:ok, %{error: _}} =
                 action(actor, :finish_verify, assertion(challenge, auth))

        %{model | challenges: model.challenges + 1}
      else
        step_fallback_verify_removed(actor, model)
      end
    else
      before = snapshot()
      assert {:error, _} = action(actor, :begin_verify)
      assert snapshot() == before
      model
    end
  end

  defp step(:lock, actor, _jti, _token, model) do
    before = snapshot()
    result = action(actor, :lock)
    assert match?({:ok, %{locked: true}}, result) == model.live
    unless model.live, do: assert(snapshot() == before)
    if model.live, do: %{model | elevated: false}, else: model
  end

  defp step(:register, actor, _jti, _token, model) do
    allowed =
      model.live and model.elevated and map_size(model.creds) < 10 and model.challenges < 10

    if allowed do
      known = Map.keys(model.creds)
      {:ok, challenge} = action(actor, :begin_register)
      auth = authenticator()

      assert {:ok, %{registered: true}} =
               action(actor, :finish_register, registration(challenge, auth))

      [id] =
        actor.id
        |> Kernel.then(&Ledger.read!(Passkey, user_id: &1))
        |> Enum.map(& &1.id)
        |> Kernel.--(known)

      %{
        model
        | creds: Map.put(model.creds, id, %{label: "Test passkey", auth: auth}),
          challenges: model.challenges + 1
      }
    else
      before = snapshot()
      assert {:error, _} = action(actor, :begin_register)
      assert snapshot() == before
      model
    end
  end

  defp step(:revoke_login, _actor, _jti, token, model) do
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)
    %{model | live: false, elevated: false}
  end

  @spec step_fallback_verify_removed(Marshall.Accounts.User.t(), model()) :: model()
  defp step_fallback_verify_removed(actor, model) do
    # Nothing was ever removed: a fresh unknown authenticator drives the same
    # failed ceremony with no inventory change.
    {:ok, challenge} = action(actor, :begin_verify)

    assert {:ok, %{error: _}} =
             action(actor, :finish_verify, assertion(challenge, authenticator()))

    %{model | challenges: model.challenges + 1}
  end

  @spec credential_pick(%{String.t() => credential()}, non_neg_integer()) :: String.t()
  defp credential_pick(creds, pick) do
    ids = sorted_ids(creds)

    cond do
      ids == [] -> @bogus
      rem(pick, 7) == 0 -> @bogus
      true -> Enum.at(ids, rem(pick, length(ids)))
    end
  end

  @spec sorted_ids(%{String.t() => credential()}) :: [String.t()]
  defp sorted_ids(creds), do: creds |> Map.keys() |> Enum.sort()

  defp snapshot do
    for table <- [
          "account_passkeys",
          "account_verifications",
          "tokens",
          "account_passkey_challenges",
          "account_admin_events"
        ] do
      %{rows: rows, columns: columns} =
        Ecto.Adapters.SQL.query!(Repo, "SELECT * FROM " <> table <> " ORDER BY 1, 2", [],
          log: false
        )

      {table, columns, rows}
    end
  end

  @spec assert_state(Marshall.Accounts.User.t(), model()) :: :ok
  defp assert_state(actor, model) do
    jti = Security.jti(actor)
    inventory = Map.new(Ledger.read!(Passkey, user_id: actor.id), &{&1.id, &1.label})
    expected = Map.new(model.creds, fn {id, cred} -> {id, cred.label} end)
    assert inventory == expected

    current = Security.current(actor.id)
    assert current.mfa_enabled == model.mfa_enabled
    assert current.mfa_generation == model.generation

    assert Security.recent?(actor) == model.elevated,
           "elevation mismatch after proving=#{inspect(model.proving)}"

    assert Security.passkey_verified?(jti, actor.id) == model.verified
    assert match?({:ok, _}, Login.token_present(jti, actor.id)) == model.live
    assert match?({:ok, _}, Login.present(jti, actor.id)) == model.live

    assert length(Ledger.read!(PasskeyChallenge, user_id: actor.id)) == model.challenges
    :ok
  end
end
