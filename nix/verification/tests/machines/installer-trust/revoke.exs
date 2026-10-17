# @cc [owner:ghuntley,label:verification;security] installer-disposable-revocation
# Only this isolated fixture may withdraw the seeded user's active keys, and only
# through the real owner-scoped revocation action; an unattended eval cannot
# honestly hold the live MFA elevation the administrator action requires.
require Ash.Query

{:ok, _} = Application.ensure_all_started(:marshall)

user =
  Marshall.Accounts.User
  |> Ash.Query.for_read(:internal_lookup, %{},
    actor: Marshall.Authorization.SystemActor.compute()
  )
  |> Ash.Query.filter(email == "installer@example.test")
  |> Ash.read_one!()

{:ok, keys} = Marshall.SSH.list_keys(%{}, actor: user)

Enum.each(keys, fn key ->
  {:ok, %{revoked: true}} = Marshall.SSH.remove_key(%{id: key.id}, actor: user)
end)
