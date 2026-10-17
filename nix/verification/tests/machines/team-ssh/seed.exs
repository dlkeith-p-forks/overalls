# @cc [owner:ghuntley,label:verification;security] teams-ssh-fixture-authority
# Test identities and public keys MAY be seeded only inside this isolated fixture.
# The bootstrap latch MUST be complete and tested users MUST remain ordinary.
# Gateway credentials MUST stay private; tested team actions MUST use Porsche.
{:ok, _} = Application.ensure_all_started(:marshall)

Ash.Seed.seed!(Marshall.Accounts.User, %{
  email: "team-bootstrap@example.test",
  administrator: true
})

[bootstrap] = Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")
Marshall.Compute.Ledger.update!(bootstrap, :complete, %{})

for name <- ["owner", "target", "foreign"] do
  user = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "team-#{name}@example.test"})
  public_key = File.read!("/run/overalls-test/#{name}.pub") |> String.trim()
  {:ok, _} = Marshall.SSH.add_key(%{public_key: public_key}, actor: user)
end

{:ok, _} = Marshall.Operations.SSHGateway.prepare("/run/overalls-test/gateway.token")
{:ok, _} = Marshall.Operations.SSHGateway.configure("team-ssh", "/run/overalls-test/gateway.token")
