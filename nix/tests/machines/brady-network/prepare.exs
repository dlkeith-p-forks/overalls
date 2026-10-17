alias Lilly.Network.{Config, Guest, Policy}
host = "11111111-1111-4111-8111-111111111111"
proxy = %{"uid" => 991, "http_ports" => [80], "https_ports" => [443], "dns" => ["8.8.8.8"]}
{:ok, config} = Config.new(host, "eth0", ["8.8.4.5/32"], "/var/lib/brady-network", true, true, proxy)
{:ok, guest} = Guest.new(host, :standard, 2)
{:ok, guest2} = Guest.new("33333333-3333-4333-8333-333333333333", :standard, 4)
{:ok, customer} = Guest.new("22222222-2222-4222-8222-222222222222", :customer, 3)
File.write!("/run/brady-network.nft", Policy.router(config) <> Policy.guard(guest) <> Policy.guard(guest2) <> Policy.guard(customer))
File.write!("/run/brady-network.json", JSON.encode!(%{namespace: config.namespace,
  guest2: Map.take(guest2, [:tap, :address, :gateway, :mac]),
  guest: Map.take(guest, [:tap, :address, :gateway, :mac]),
  customer: Map.take(customer, [:tap, :address, :gateway, :mac])}))
