defmodule Lilly.Transfer.EndpointTest do
  # capture_log observes global Logger traffic, including other tests' transfer
  # effects. Serialize this module so silence and reason assertions are isolated.
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Lilly.Transfer.Endpoint
  @moduletag :tmp_dir
  @host "00000000-0000-0000-0000-000000000004"
  @pool "00000000-0000-0000-0000-000000000005"

  property "export failure diagnostics exclude arbitrary and wrapped payloads" do
    bytes = draw("bytes", binary(min_length: 1, max_length: 128))
    wrapped = draw("wrapped", boolean())
    secret = "private-export-" <> Base.encode16(bytes)
    result = if wrapped, do: {:error, {:storage_busy, secret}}, else: {:error, secret}

    log =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        stdout =
          ExUnit.CaptureIO.capture_io(fn ->
            assert Endpoint.export_status(result) == 1
          end)

        assert stdout == ""
      end)

    assert log =~ "lilly.transfer_export_failed"
    assert log =~ "export_unconfirmed"
    refute log =~ secret
    refute log =~ "storage_busy"
  end

  test "successful export is silent and known source failures retain a closed reason" do
    assert ExUnit.CaptureLog.capture_log(fn -> assert Endpoint.export_status(:ok) == 0 end) == ""

    for reason <- [
          :storage_busy,
          :source_snapshot_unconfirmed,
          :exporter_expired,
          :exporter_revoked,
          :export_worker_exception
        ] do
      log =
        ExUnit.CaptureLog.capture_log([metadata: [:reason]], fn ->
          assert Endpoint.export_status({:error, reason}) == 1
        end)

      assert log =~ Atom.to_string(reason)
    end
  end

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)

    config = %{
      "version" => 3,
      "host_id" => @host,
      "root" => Path.join(root, "permits"),
      "pools" => [
        %{
          "id" => @pool,
          "path" => Path.join(root, "pool"),
          "filesystem_id" => "zfs:1:2",
          "storage" => %{
            "backend" => "zfs",
            "zpool_guid" => "1",
            "dataset_guid" => "2",
            "dataset" => "tank/lilly"
          }
        }
      ]
    }

    %{config: config, path: Path.join(root, "config.json")}
  end

  defp write(c, config) do
    File.write!(c.path, JSON.encode!(config))
    File.chmod!(c.path, 0o600)
    c.path
  end

  test "loading trusted config does not inspect pools or create journals", c do
    assert {:ok, config} = Endpoint.load(write(c, c.config))
    assert config.host_id == @host
    refute File.exists?(config.root)
    refute File.exists?(hd(config.pools)["path"])
  end

  test "closed configuration rejects malformed identities, retired budgets and overlapping paths",
       c do
    [pool] = c.config["pools"]

    variants = [
      Map.put(c.config, "credential", "not-allowed"),
      %{c.config | "version" => 2},
      %{c.config | "root" => c.config["root"] <> "/../permits"},
      %{c.config | "pools" => []},
      %{c.config | "pools" => [pool, pool]},
      %{c.config | "pools" => [%{pool | "storage" => %{}}]},
      %{c.config | "pools" => [%{pool | "filesystem_id" => "zfs:9:2"}]},
      %{c.config | "pools" => [Map.put(pool, "logical_budget_bytes", 2_147_483_648)]},
      %{c.config | "pools" => [Map.put(pool, "unknown", 1)]},
      %{c.config | "pools" => [%{pool | "path" => c.config["root"] <> "/child"}]}
    ]

    for variant <- variants do
      assert {:error, :export_endpoint_unconfirmed} = Endpoint.load(write(c, variant))
    end
  end

  test "unsafe configuration files and absent permits cannot authorize or export", c do
    path = write(c, c.config)
    encoded = Base.encode64(<<11::32, "ssh-ed25519", 32::32, 1::256>>)
    assert {:error, _} = Endpoint.authorize(path, "root", "ssh-ed25519", encoded, "/bin/export")

    assert {:error, _} =
             Endpoint.authorize(path, "lilly-transfer", "ssh-ed25519", encoded, "/bin/export")

    assert {:error, _} =
             Endpoint.run(
               path,
               encoded,
               "lilly-export-v4 00000000-0000-0000-0000-000000000001"
             )

    refute File.exists?(c.config["root"])
    File.chmod!(path, 0o644)
    assert {:error, _} = Endpoint.load(path)
    File.chmod!(path, 0o600)
    File.ln_s!(path, path <> ".link")
    assert {:error, _} = Endpoint.load(path <> ".link")
  end
end
