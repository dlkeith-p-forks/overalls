defmodule Marshall.Accounts.LocaleTest do
  use Marshall.DataCase, async: false
  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  require Ash.Query

  @spec set(term(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  defp set(actor, locale) do
    User
    |> Ash.ActionInput.for_action(:set_locale, %{locale: locale}, actor: actor)
    |> Ash.run_action()
  end

  @spec stored(String.t()) :: String.t() | nil
  defp stored(id) do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!()
    |> Map.fetch!(:locale)
  end

  test "every supported locale round-trips and nil restores browser detection" do
    user = Marshall.ComputeFixtures.user()

    for locale <- Marshall.Localization.supported_locales() do
      assert {:ok, %{locale: ^locale}} = set(user, locale)
      assert stored(user.id) == locale
    end

    assert {:ok, %{locale: nil}} = set(user, nil)
    assert stored(user.id) == nil
    assert {:ok, %{locale: "pt-BR"}} = set(user, "pt-br")
    assert stored(user.id) == "pt-BR"
  end

  test "a user cannot change another account or persist unsupported input" do
    actor = Marshall.ComputeFixtures.user()
    other = Marshall.ComputeFixtures.user()
    assert {:ok, _} = set(actor, "ja")

    for bad <- ["invalid", "<script>", "", String.duplicate("a", 36)] do
      assert {:error, _} = set(actor, bad)
      assert stored(actor.id) == "ja"
    end

    assert {:error, _} =
             User
             |> Ash.ActionInput.for_action(:set_locale, %{locale: "hi", user_id: other.id},
               actor: actor
             )
             |> Ash.run_action()

    assert stored(other.id) == nil
    assert stored(actor.id) == "ja"
    assert {:error, _} = set(nil, "ar")
    assert {:error, _} = set(SystemActor.compute(), "ar")
  end

  test "retired accounts cannot change language" do
    user = Marshall.ComputeFixtures.user()
    Marshall.Compute.Ledger.update!(user, :security_state, %{deleted_at: DateTime.utc_now()})
    assert {:error, _} = set(user, "ar")
    assert stored(user.id) == nil
  end

  test "the internal resource action validates the supported locale list" do
    user = Marshall.ComputeFixtures.user()

    assert {:error, _} =
             user
             |> Ash.Changeset.for_update(:store_locale, %{locale: "unsupported"},
               actor: SystemActor.compute()
             )
             |> Ash.update()

    assert stored(user.id) == nil
  end
end
