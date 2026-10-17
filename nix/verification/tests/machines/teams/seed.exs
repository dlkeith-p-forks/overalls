# @cc [owner:ghuntley,label:security;verification] teams-fixture-token-custody
# Disposable login tokens MUST stay in private files. The three browser accounts
# MUST remain ordinary after login. A separate unused administrator and completed
# bootstrap latch MUST represent an installed system; all team mutations use the
# browser.
{:ok, _} = Application.ensure_all_started(:marshall)

Ash.Seed.seed!(Marshall.Accounts.User, %{
  email: "team-bootstrap@example.test",
  administrator: true
})

[bootstrap] =
  Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")

Marshall.Compute.Ledger.update!(bootstrap, :complete, %{})

for name <- ["owner", "target", "admin"] do
  user = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "team-#{name}@example.test"})
  strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
  {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
  path = "/run/overalls-test/team-#{name}-token"
  File.write!(path, token)
  File.chmod!(path, 0o600)
end
