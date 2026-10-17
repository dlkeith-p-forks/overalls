# Run with MIX_ENV=test and a fresh, dedicated MIX_TEST_PARTITION after ash.setup.
# Stop the process and remove the private output file after the browser probe.
if Mix.env() != :test or System.get_env("MIX_TEST_PARTITION", "") == "" do
  raise "passkey browser fixture requires a dedicated test partition"
end

port = String.to_integer(System.fetch_env!("PASSKEY_BROWSER_PORT"))
output = System.fetch_env!("PASSKEY_BROWSER_CONTEXT")
config = Application.fetch_env!(:marshall, MarshallWeb.Endpoint)

Application.put_env(
  :marshall,
  MarshallWeb.Endpoint,
  config
  |> Keyword.put(:server, true)
  |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: port)
  |> Keyword.put(:url, host: "localhost", scheme: "http", port: port)
)

{:ok, _} = Application.ensure_all_started(:marshall)
Logger.configure(level: :warning)
Ecto.Adapters.SQL.Sandbox.mode(Marshall.Repo, :auto)
alias Marshall.Compute.Ledger
alias Marshall.Accounts.{User, AdminBootstrap}
bootstrap = Ledger.lock!(AdminBootstrap, "installation")
Ledger.update!(bootstrap, :complete, %{})

admin =
  Ash.Seed.seed!(User, %{
    email: "admin-#{Ash.UUID.generate()}@example.test",
    administrator: true
  })

victim = Ash.Seed.seed!(User, %{email: "victim-#{Ash.UUID.generate()}@example.test"})
strategy = AshAuthentication.Info.strategy!(User, :magic_link)
{:ok, first} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, admin)
{:ok, second} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, admin)

File.open!(output, [:write, :exclusive], fn file ->
  File.chmod!(output, 0o600)

  IO.binwrite(
    file,
    JSON.encode!(%{
      origin: "http://localhost:#{port}",
      admin_token: first,
      second_token: second,
      victim_id: victim.id,
      victim_email: to_string(victim.email)
    })
  )
end)

System.at_exit(fn _ -> File.rm(output) end)
Process.sleep(:infinity)
