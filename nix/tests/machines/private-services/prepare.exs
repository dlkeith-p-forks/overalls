alias Lilly.Network.{Config, Guest, Policy}
host = "11111111-1111-4111-8111-111111111111"
{:ok, config} = Config.new(host, "eth0", [], "/var/lib/private-network", false, true)
{:ok, guest} = Guest.new(host, :standard, 2)
{:ok, customer} = Guest.new("22222222-2222-4222-8222-222222222222", :customer, 3)

File.write!(
  "/run/private-network.nft",
  Policy.router(config) <> Policy.guard(guest) <> Policy.guard(customer)
)

File.write!(
  "/run/private-network.json",
  JSON.encode!(%{
    namespace: config.namespace,
    guest: Map.take(guest, [:tap, :address, :gateway, :mac]),
    customer: Map.take(customer, [:tap, :address, :gateway, :mac])
  })
)
