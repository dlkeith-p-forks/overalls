defmodule Lilly.Control.ClientTest do
  use ExUnit.Case, async: true
  alias Lilly.Control.Client
  @id "11111111-1111-4111-8111-111111111111"
  @machine "sha256:" <> String.duplicate("a", 64)
  @token @id <> ":" <> String.duplicate("a", 43)

  test "HTTPS is required except for an explicitly enabled literal loopback address" do
    assert {:ok, _} =
             Client.new("https://marshall.example.test", @id, @token, machine_id: @machine)

    for url <- [
          "http://127.0.0.1",
          "http://example.test",
          "http://localhost",
          "ftp://example.test",
          "https://user@example.test",
          "https://example.test/?token=private",
          "https://example.test/extra",
          "https://[::1]",
          "https://[2001:db8::1]",
          "https://example.test/#fragment"
        ] do
      assert {:error, :invalid_configuration} = Client.new(url, @id, @token, machine_id: @machine)
    end

    assert {:ok, _} =
             Client.new("http://127.0.0.1:4000", @id, @token,
               allow_insecure_loopback: true,
               machine_id: @machine
             )

    assert {:error, :invalid_configuration} =
             Client.new("http://[::1]:4000", @id, @token,
               allow_insecure_loopback: true,
               machine_id: @machine
             )

    assert {:error, :invalid_configuration} =
             Client.new("http://example.test", @id, @token,
               allow_insecure_loopback: true,
               machine_id: @machine
             )
  end

  test "client inspection excludes the credential" do
    {:ok, client} = Client.new("https://example.test", @id, @token, machine_id: @machine)
    assert not String.contains?(inspect(client), @token)
  end

  test "executable transport requires an explicit version and physical host identity" do
    machine = "sha256:" <> String.duplicate("a", 64)

    assert {:ok, client} =
             Client.new("https://example.test", @id, @token,
               protocol_version: 4,
               machine_id: machine
             )

    assert client.protocol_version == 4

    for options <- [
          [protocol_version: 4],
          [protocol_version: 4],
          [protocol_version: 1, machine_id: machine],
          [protocol_version: 4, machine_id: "host"]
        ] do
      assert {:error, :invalid_configuration} =
               Client.new("https://example.test", @id, @token, options)
    end
  end
end
