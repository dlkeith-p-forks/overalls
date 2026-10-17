defmodule Marshall.Enrico.ClientTest do
  use ExUnit.Case, async: false

  alias Marshall.Enrico.Client

  @tls Path.expand("../../fixtures/tls", __DIR__)
  @repo_id "883d5b5d-05fb-43b3-84ed-379ccf289072"

  @tag :tmp_dir
  test "the client verifies the server certificate against its configured CA", %{tmp_dir: dir} do
    server =
      start_supervised!(
        {Bandit,
         plug: MarshallWeb.FleetEndpoint,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@tls, "localhost.pem"),
         keyfile: Path.join(@tls, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    token_file = Path.join(dir, "token")
    File.write!(token_file, String.duplicate("a", 32))

    for {key, value} <- [
          enrico_url: "https://localhost:#{port}",
          enrico_token_file: token_file,
          enrico_ca_file: Path.join(@tls, "ca.pem")
        ] do
      previous = Application.get_env(:marshall, key)
      Application.put_env(:marshall, key, value)

      on_exit({key, :restore}, fn ->
        if previous == nil,
          do: Application.delete_env(:marshall, key),
          else: Application.put_env(:marshall, key, previous)
      end)
    end

    assert {:error, :not_found} = Client.request(:get, @repo_id)

    Application.put_env(:marshall, :enrico_ca_file, "/etc/ssl/certs/ca-certificates.crt")
    assert {:error, :tls_untrusted} = Client.request(:get, @repo_id)
  end
end
