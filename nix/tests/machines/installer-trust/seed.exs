# @cc [owner:ghuntley,label:verification] installer-disposable-authority
# Only this isolated fixture may seed a user and register its public SSH key.
# Gateway credentials MUST stay in private files and MUST NOT be printed.
{:ok, _} = Application.ensure_all_started(:marshall)
user = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "installer@example.test"})
public_key = File.read!("/run/overalls-test/client.pub") |> String.trim()
{:ok, _} = Marshall.SSH.add_key(%{public_key: public_key}, actor: user)
{:ok, _} = Marshall.Operations.SSHGateway.prepare("/run/overalls-test/gateway.token")
{:ok, _} = Marshall.Operations.SSHGateway.configure("installer", "/run/overalls-test/gateway.token")
