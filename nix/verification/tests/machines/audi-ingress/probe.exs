alias Lilly.Network.{Config, Guest, Ingress, Policy}
host = "11111111-1111-4111-8111-111111111111"
{:ok, network} = Config.new(host, "eth0", [], "/var/lib/ingress-fixture", true, true)
{:ok, first} = Guest.new(host, :customer, 2)
{:ok, second} = Guest.new("22222222-2222-4222-8222-222222222222", :standard, 3)

case System.fetch_env!("INGRESS_CHECK") do
  "prepare" ->
    File.write!(
      "/run/ingress.nft",
      Policy.router(network) <> Policy.guard(first) <> Policy.guard(second)
    )

    File.write!(
      "/run/ingress.json",
      JSON.encode!(%{
        namespace: network.namespace,
        guests: Enum.map([first, second], &Map.take(&1, [:tap, :address, :gateway, :mac]))
      })
    )

  "marked" ->
    for guest <- [first, second] do
      {:ok, socket} = Ingress.connect(network, guest)
      :ok = :gen_tcp.send(socket, "ingress-fixture")
      {:ok, "ingress-fixture"} = :gen_tcp.recv(socket, 15, 1000)
      :gen_tcp.close(socket)
    end

  "web" ->
    for guest <- [second], port <- [80, 443, 3000, 9999] do
      {:ok, socket} = Ingress.connect(network, guest, %{service: :web, port: port})
      :ok = :gen_tcp.send(socket, "web-fixture")
      {:ok, "web-fixture"} = :gen_tcp.recv(socket, 11, 1000)
      :gen_tcp.close(socket)
    end

    {:error, :ingress_unavailable} = Ingress.connect(network, first, %{service: :tcp, port: 80})
    {:error, :ingress_unavailable} = Ingress.connect(network, first, %{service: :ssh, port: 80})

    {:error, :ingress_unavailable} =
      Ingress.connect(%{network | ingress: false}, first, %{service: :web, port: 80})

  "customer-web" ->
    for port <- [22, 80, 443, 3000, 9999, 65535] do
      {:error, :ingress_unavailable} =
        Ingress.connect(network, first, %{service: :web, port: port})

      {:ok, address} = :inet.parse_ipv4_address(String.to_charlist(first.address))

      options = [
        {:inet_backend, :inet},
        :binary,
        {:active, false},
        {:netns, String.to_charlist("/run/netns/" <> network.namespace)},
        {:bind_to_device, first.tap},
        {:raw, 1, 36, <<Policy.ingress_mark(:web)::native-unsigned-32>>}
      ]

      {:error, _} = :gen_tcp.connect(address, port, options, 400)
    end

  "editor-mark" ->
    # Actual Linux marks and production policy, without simulating broker
    # admission: the echo fixture establishes only the network boundary.
    for guest <- [first, second] do
      {:ok, address} = :inet.parse_ipv4strict_address(String.to_charlist(guest.address))
      {:ok, source} = :inet.parse_ipv4strict_address(String.to_charlist(guest.gateway))

      base = [
        {:inet_backend, :inet},
        :binary,
        {:active, false},
        {:ip, source},
        {:netns, String.to_charlist("/run/netns/" <> network.namespace)},
        {:bind_to_device, guest.tap}
      ]

      editor = base ++ [{:raw, 1, 36, <<Policy.ingress_mark(:editor)::native-unsigned-32>>}]
      web = base ++ [{:raw, 1, 36, <<Policy.ingress_mark(:web)::native-unsigned-32>>}]
      {:ok, socket} = :gen_tcp.connect(address, 4444, editor, 1000)
      :ok = :gen_tcp.send(socket, "editor-fixture")
      {:ok, "editor-fixture"} = :gen_tcp.recv(socket, 14, 1000)
      :gen_tcp.close(socket)
      {:error, _} = :gen_tcp.connect(address, 4444, web, 400)

      for port <- [22, 23, 80, 443, 3000, 9999] do
        {:error, _} = :gen_tcp.connect(address, port, editor, 400)
      end

      {:error, :ingress_unavailable} =
        Ingress.connect(network, guest, %{service: :web, port: 4444})
    end

  "disabled" ->
    {:error, :ingress_unavailable} = Ingress.connect(%{network | ingress: false}, first)

  mode when mode in ["unmarked", "wrong-port"] ->
    mark =
      if mode == "unmarked",
        do: [],
        else: [{:raw, 1, 36, <<Policy.ingress_mark()::native-unsigned-32>>}]

    options =
      [
        {:inet_backend, :inet},
        :binary,
        {:active, false},
        {:netns, String.to_charlist("/run/netns/" <> network.namespace)},
        {:bind_to_device, first.tap}
      ] ++ mark

    {:ok, address} = :inet.parse_ipv4_address(String.to_charlist(first.address))

    {:error, _} =
      :gen_tcp.connect(address, if(mode == "wrong-port", do: 23, else: 22), options, 400)
end
