# @cc [owner:ghuntley,label:verification] installer-disposable-reregister
# Only this isolated fixture may register the seeded user's fresh public key
# through the real owner-scoped action after a revocation probe.
require Ash.Query

{:ok, _} = Application.ensure_all_started(:marshall)

user =
  Marshall.Accounts.User
  |> Ash.Query.for_read(:internal_lookup, %{},
    actor: Marshall.Authorization.SystemActor.compute()
  )
  |> Ash.Query.filter(email == "installer@example.test")
  |> Ash.read_one!()

public_key = File.read!("/run/overalls-test/client.pub") |> String.trim()
{:ok, _} = Marshall.SSH.add_key(%{public_key: public_key}, actor: user)
