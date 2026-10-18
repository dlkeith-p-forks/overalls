defmodule Ziggy.BootstrapReleaseTest do
  use ExUnit.Case, async: true

  @spec fixture() :: String.t()
  defp fixture do
    root = Path.join(System.tmp_dir!(), "ziggy-bootstrap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    platforms =
      Map.new(~w(linux-amd64 windows-amd64 freebsd-amd64 illumos-amd64), fn platform ->
        path = platform <> if(platform == "windows-amd64", do: "/executor.exe", else: "/executor")
        bytes = "synthetic-executor-" <> platform
        File.mkdir_p!(Path.join(root, platform))
        File.write!(Path.join(root, path), bytes)
        digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        {platform, %{"path" => path, "sha256" => digest, "bytes" => byte_size(bytes)}}
      end)

    File.write!(
      Path.join(root, "manifest.json"),
      Jason.encode!(%{"version" => 1, "platforms" => platforms})
    )

    root
  end

  test "bootstrap inventory verifies every executable before exposing digest selectors" do
    root = fixture()
    assert {:ok, %{artifacts: artifacts}} = Ziggy.BootstrapRelease.load(root)
    assert map_size(artifacts) == 4
    File.write!(Path.join(root, "windows-amd64/executor.exe"), "corrupt")
    assert {:error, :invalid_configuration} = Ziggy.BootstrapRelease.load(root)
  end

  test "absent release and malformed paths have explicit outcomes" do
    assert {:ok, nil} = Ziggy.BootstrapRelease.load(nil)

    for value <- ["relative", 1, %{}] do
      assert {:error, :invalid_configuration} = Ziggy.BootstrapRelease.load(value)
    end
  end
end
