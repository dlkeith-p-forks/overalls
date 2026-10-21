defmodule Peach.ConfigTest do
  use ExUnit.Case, async: true

  @host "01234567-89ab-4def-8123-456789abcdef"

  setup do
    dir = Path.join(System.tmp_dir!(), "peach-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    token = @host <> "." <> String.duplicate("k", 43)
    credential = Path.join(dir, "control.token")
    File.write!(credential, token <> "\n")
    File.chmod!(credential, 0o400)
    ca = Path.join(dir, "ca.pem")
    File.write!(ca, "placeholder")

    value = %{
      "version" => 1,
      "host_id" => @host,
      "control_plane" => "https://control.example.invalid",
      "ca_file" => ca,
      "credential_file" => credential,
      "socket" => Path.join(dir, "reflection.sock")
    }

    {:ok, dir: dir, value: value, token: token}
  end

  test "loads a strict closed configuration", %{dir: dir, value: value, token: token} do
    assert {:ok, %{host_id: @host, control: %{token: ^token, host_id: @host}}} =
             Peach.Config.load(write(dir, value))
  end

  test "rejects extra keys, plain HTTP, store paths and bad credentials", %{
    dir: dir,
    value: value
  } do
    for bad <- [
          Map.put(value, "extra", true),
          Map.delete(value, "socket"),
          %{value | "version" => 2},
          %{value | "host_id" => "host"},
          %{value | "control_plane" => "http://control.example.invalid"},
          %{value | "control_plane" => "https://control.example.invalid/path"},
          %{value | "socket" => "/nix/store/x/reflection.sock"},
          %{value | "socket" => "relative.sock"},
          %{value | "credential_file" => Path.join(dir, "missing")},
          %{value | "ca_file" => Path.join(dir, "missing.pem")}
        ] do
      assert {:error, :invalid_configuration} = Peach.Config.load(write(dir, bad))
    end

    assert {:error, :invalid_configuration} = Peach.Config.load(Path.join(dir, "absent.json"))
    assert {:error, :invalid_configuration} = Peach.Config.load(nil)
  end

  test "no configuration starts no children; a rejected one stops startup", %{dir: dir} do
    assert {:ok, []} = Peach.Application.children(nil)
    File.write!(Path.join(dir, "bad.json"), "{}")

    assert {:error, :invalid_configuration} =
             Peach.Application.children(Path.join(dir, "bad.json"))
  end

  defp write(dir, value) do
    path = Path.join(dir, "config-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(value))
    path
  end
end
