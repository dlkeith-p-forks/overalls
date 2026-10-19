# @cc [owner:ghuntley,label:security;verification] mila-desktop-fixture-custody
# This isolated fixture MAY seed one ordinary user and a disposable magic-link
# token in a private VM file; the token MUST NOT be printed. The bootstrap
# latch MUST be complete, the Mila user MUST stay ordinary, and the device key
# MUST be approved only through the real browser ceremony, never seeded.
{:ok, _} = Application.ensure_all_started(:marshall)

Ash.Seed.seed!(Marshall.Accounts.User, %{
  email: "mila-bootstrap@example.test",
  administrator: true
})

[bootstrap] = Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")
Marshall.Compute.Ledger.update!(bootstrap, :complete, %{})

user = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "mila@example.test"})
strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
{:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
File.write!("/run/overalls-test/mila-token", token)
File.chmod!("/run/overalls-test/mila-token", 0o600)

{:ok, _} = Marshall.Operations.SSHGateway.prepare("/run/overalls-test/gateway.token")
{:ok, _} = Marshall.Operations.SSHGateway.configure("mila-desktop", "/run/overalls-test/gateway.token")
