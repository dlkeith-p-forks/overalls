defmodule Marshall.Accounts.AdminAccountHistoryTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Accounts.{AdminEvent, Passkey, Security, User, UserDeletion}
  alias Marshall.Compute.Ledger
  alias Marshall.AdminAccountFixture, as: Fixture
  alias Marshall.PasskeyFixture

  @typep command :: :mutate | :lock | :verify | :signout | :login | :demote | :promote
  @typep model :: %{
           challenges: non_neg_integer(),
           administrator: boolean(),
           live: boolean(),
           elevated: boolean(),
           target_administrator: boolean(),
           generation: non_neg_integer(),
           reset: boolean(),
           retired: boolean(),
           keys: 0 | 1,
           mutations: non_neg_integer(),
           receipts: [:grant | :sessions_revoke | :mfa_reset | :user_delete | :user_invite]
         }

  # @cc [owner:ghuntley,label:verification;security] admin-account-history-oracle
  # Generated histories MUST invoke real public account actions and derive
  # permission from command history, never from Cedar or Security.recent?. Every
  # refusal MUST preserve the complete fixture inventory, including tokens,
  # credentials, outbox/jobs, retirement and audit rows.
  for operation <- [:role, :sessions, :reset, :retire, :invite] do
    @operation operation
    property "#{@operation} follows current role, login and elevation history" do
      check all(
              tail <-
                list_of(member_of([:mutate, :lock, :verify, :signout, :login, :demote, :promote]),
                  max_length: 14
                ),
              max_runs: 12
            ) do
        actor = PasskeyFixture.elevate(PasskeyFixture.user(true))
        operator = PasskeyFixture.elevate(PasskeyFixture.user(true))
        target = PasskeyFixture.elevate(PasskeyFixture.user())

        model = %{
          challenges: 2,
          administrator: true,
          live: true,
          elevated: true,
          target_administrator: false,
          generation: 0,
          reset: false,
          retired: false,
          keys: 1,
          mutations: 0,
          receipts: []
        }

        history =
          [
            :lock,
            :mutate,
            :verify,
            :mutate,
            :signout,
            :mutate,
            :login,
            :mutate,
            :verify,
            :demote,
            :mutate,
            :promote
          ] ++ tail

        Enum.reduce(history, {actor, model}, fn command, {actor, model} ->
          {actor, model} = step(command, @operation, actor, operator, target, model)
          assert_model(actor, target, @operation, model)
          {actor, model}
        end)
      end
    end
  end

  @spec step(command(), Fixture.operation(), User.t(), User.t(), User.t(), model()) ::
          {User.t(), model()}
  defp step(:mutate, operation, actor, _operator, target, model) do
    before = Fixture.snapshot(actor, target)

    allowed =
      model.administrator and model.live and model.elevated and
        (not model.retired or operation in [:sessions, :retire, :invite])

    result = Fixture.act(operation, %{actor | administrator: true}, target)

    if allowed do
      assert {:ok, _} = result
      {actor, advance(operation, model)}
    else
      assert {:error, _} = result
      assert Fixture.snapshot(actor, target) == before
      {actor, model}
    end
  end

  defp step(:lock, _operation, actor, _operator, _target, model) do
    result = PasskeyFixture.action(actor, :lock)
    if model.live, do: assert(match?({:ok, _}, result)), else: assert(match?({:error, _}, result))
    {actor, %{model | elevated: false}}
  end

  defp step(:verify, _operation, actor, _operator, _target, model) do
    if model.live and model.challenges < 10 do
      assert {:ok, %{verified: true}} =
               PasskeyFixture.verify(actor, actor.__metadata__.test_authenticator)

      {actor, %{model | elevated: true, challenges: model.challenges + 1}}
    else
      assert {:error, _} = PasskeyFixture.action(actor, :begin_verify)
      {actor, model}
    end
  end

  defp step(:signout, _operation, actor, _operator, target, model) do
    assert {:ok, _} = Fixture.act(:signout, actor, target)
    {actor, %{model | live: false, elevated: false}}
  end

  defp step(:login, _operation, actor, _operator, _target, model) do
    key = actor.__metadata__.test_authenticator
    {new_actor, token} = PasskeyFixture.login(Security.current(actor.id))

    new_actor =
      new_actor
      |> Ash.Resource.put_metadata(:token, token)
      |> Ash.Resource.put_metadata(:test_authenticator, key)

    {new_actor, %{model | live: true, elevated: false}}
  end

  defp step(command, _operation, actor, operator, _target, model)
       when command in [:demote, :promote] do
    enabled = command == :promote
    assert {:ok, _} = Marshall.JobHistoryFixture.role(operator, actor, enabled)
    {actor, %{model | administrator: enabled}}
  end

  @spec advance(Fixture.operation(), model()) :: model()
  defp advance(:role, model) do
    if model.target_administrator,
      do: model,
      else: %{
        model
        | target_administrator: true,
          receipts: model.receipts ++ [:grant],
          mutations: model.mutations + 1
      }
  end

  defp advance(:sessions, model),
    do: %{model | receipts: model.receipts ++ [:sessions_revoke], mutations: model.mutations + 1}

  defp advance(:reset, model),
    do: %{
      model
      | generation: model.generation + 1,
        reset: true,
        keys: 0,
        receipts: model.receipts ++ [:mfa_reset],
        mutations: model.mutations + 1
    }

  defp advance(:retire, model) do
    if model.retired,
      do: model,
      else: %{
        model
        | retired: true,
          target_administrator: false,
          generation: model.generation + 1,
          receipts: model.receipts ++ [:user_delete],
          mutations: model.mutations + 1
      }
  end

  defp advance(:invite, model),
    do: %{model | receipts: model.receipts ++ [:user_invite], mutations: model.mutations + 1}

  @spec assert_model(User.t(), User.t(), Fixture.operation(), model()) :: :ok
  defp assert_model(actor, target, operation, model) do
    current = Security.current(target.id)
    assert current.administrator == model.target_administrator
    assert current.mfa_generation == model.generation
    assert current.mfa_reset_required == model.reset
    assert not is_nil(current.deleted_at) == model.retired
    assert length(Ledger.read!(Passkey, user_id: target.id)) == model.keys

    assert length(Ledger.read!(UserDeletion, user_id: target.id)) ==
             if(model.retired, do: 1, else: 0)

    kinds = [:grant, :sessions_revoke, :mfa_reset, :user_delete, :user_invite]
    receipts = Ledger.read!(AdminEvent, actor_id: actor.id) |> Enum.filter(&(&1.kind in kinds))
    assert Enum.sort(Enum.map(receipts, & &1.kind)) == Enum.sort(model.receipts)

    assert Enum.all?(
             receipts,
             &(&1.target_id == if(operation == :invite, do: actor.id, else: target.id))
           )

    if model.mutations > 0 and operation in [:sessions, :reset, :retire] do
      assert Fixture.query(
               "SELECT count(*) FROM tokens WHERE subject=$1 AND purpose IN ('user', 'remember_me')",
               ["user?id=" <> target.id]
             ).rows == [[0]]
    end

    :ok
  end
end
