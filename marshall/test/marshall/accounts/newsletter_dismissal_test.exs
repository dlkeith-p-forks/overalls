defmodule Marshall.Accounts.NewsletterDismissalTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger

  @spec dismiss(User.t(), User.t() | SystemActor.t() | nil) ::
          {:ok, User.t()} | {:error, term()}
  defp dismiss(user, actor),
    do: Ash.update(user, %{}, action: :dismiss_newsletter, actor: actor)

  # @cc [owner:ghuntley,label:security;verification] newsletter-dismissal-account-oracle
  # Dismissal tests MUST inspect the stored account preference after successful,
  # repeated and refused writes. A LiveView assign alone MUST NOT establish
  # account-wide persistence or refusal of foreign and retired actors.
  test "self dismissal persists and remains dismissed when repeated from a stale account" do
    owner = user()
    other = user()
    refute owner.newsletter_dismissed

    assert {:ok, %User{newsletter_dismissed: true}} = dismiss(owner, owner)
    assert %User{newsletter_dismissed: true} = Security.current(owner.id)
    assert %User{newsletter_dismissed: false} = Security.current(other.id)

    assert {:ok, %User{newsletter_dismissed: true}} = dismiss(owner, owner)
    assert %User{newsletter_dismissed: true} = Security.current(owner.id)
  end

  test "foreign, anonymous and non-user actors cannot dismiss an account invitation" do
    owner = user()
    other = user()

    for actor <- [other, nil, SystemActor.compute()] do
      assert {:error, _} = dismiss(owner, actor)
      assert %User{newsletter_dismissed: false} = Security.current(owner.id)
      assert %User{newsletter_dismissed: false} = Security.current(other.id)
    end
  end

  test "explicit input cannot reset a stored dismissal" do
    owner = user()
    assert {:ok, dismissed} = dismiss(owner, owner)

    assert {:error, _} =
             Ash.update(dismissed, %{newsletter_dismissed: false},
               action: :dismiss_newsletter,
               actor: owner
             )

    assert %User{newsletter_dismissed: true} = Security.current(owner.id)
  end

  test "a retired account cannot dismiss with an earlier actor snapshot" do
    owner = user()
    Ledger.update!(owner, :security_state, %{deleted_at: DateTime.utc_now()})

    assert {:error, _} = dismiss(owner, owner)
    assert %User{newsletter_dismissed: false} = Security.current(owner.id)
  end
end
