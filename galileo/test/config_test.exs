defmodule Galileo.ConfigTest do
  use ExUnit.Case, async: true

  @host "01234567-89ab-4def-8123-456789abcdef"

  test "loads a strict closed configuration with private custody" do
    dir = System.tmp_dir!() |> Path.join("galileo-config-#{System.unique_integer()}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    token = "01234567-89ab-4def-8123-456789abcdef." <> String.duplicate("k", 43)
    credential = Path.join(dir, "token")
    File.write!(credential, token)
    File.chmod!(credential, 0o600)

    ca = Path.join(dir, "ca.pem")
    File.write!(ca, "placeholder")

    config = Path.join(dir, "config.json")

    File.write!(config, """
    {
      "version": 1,
      "host_id": "#{@host}",
      "control_plane": "https://ghuntley.dev",
      "ca_file": "#{ca}",
      "credential_file": "#{credential}",
      "socket": "#{Path.join(dir, "proxy.sock")}"
    }
    """)

    assert {:ok, %{host_id: @host, control: %{token: ^token}}} = Galileo.Config.load(config)

    File.write!(config, """
    {
      "version": 1,
      "host_id": "#{@host}",
      "control_plane": "http://ghuntley.dev",
      "ca_file": "#{ca}",
      "credential_file": "#{credential}",
      "socket": "#{Path.join(dir, "proxy.sock")}",
      "extra": true
    }
    """)

    assert {:error, :invalid_configuration} = Galileo.Config.load(config)
  end
end
