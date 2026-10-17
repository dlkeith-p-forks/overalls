# @cc [owner:ghuntley,label:security;verification] hldd-fixture-token-custody
# This isolated machine-test seed MUST keep its disposable browser token in a
# private file and MUST NOT print it. The browser reader MUST remain ordinary
# after login. A separate unused administrator and completed bootstrap latch
# MUST represent an installed system.
{:ok, _} = Application.ensure_all_started(:marshall)

Ash.Seed.seed!(Marshall.Accounts.User, %{
  email: "handbook-bootstrap@example.test",
  administrator: true
})

[bootstrap] =
  Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")

Marshall.Compute.Ledger.update!(bootstrap, :complete, %{})

user = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "handbook-reader@example.test"})
strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
{:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
File.write!("/run/overalls-test/hldd-token", token)
File.chmod!("/run/overalls-test/hldd-token", 0o600)
