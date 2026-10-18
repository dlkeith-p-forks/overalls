defmodule Marshall.Editor.ReleasesTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Editor.Releases

  @type wire_descriptor :: %{String.t() => String.t() | pos_integer()}

  # @cc [owner:ghuntley,label:verification;security] editor-registry-finite-targets
  # Generated distinct target releases MUST normalize without atom creation and
  # remain separate in SQL admission rows. Duplicate releases, unknown targets
  # and malformed descriptors MUST refuse instead of silently selecting a row.
  property "distinct generated releases remain bound to finite configured targets",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 2_001_711 do
    commit = draw("commit", binary(length: 20)) |> Base.encode16(case: :lower)
    digest = draw("release", binary(length: 32)) |> Base.encode16(case: :lower)
    linux = descriptor(commit, digest)
    windows = descriptor(commit, different_digest(digest))
    wire = %{"version" => 1, "targets" => %{"linux-x64" => linux, "win32-x64" => windows}}
    assert {:ok, registry} = Releases.decode(wire)
    assert registry.linux_x64.release == digest
    assert registry.win32_x64.release == windows["release"]
    assert Releases.approved?(registry.linux_x64, registry)
    assert Releases.approved?(registry.win32_x64, registry)

    assert Enum.sort(Enum.map(Releases.sql_rows(registry), & &1.target)) == [
             "linux-x64",
             "win32-x64"
           ]

    assert {:error, :invalid_editor_releases} =
             wire |> put_in(["targets", "win32-x64"], linux) |> Releases.decode()
  end

  test "registry refuses unversioned, extra, foreign and malformed configuration" do
    release = Marshall.EditorFixture.descriptor()
    valid = Marshall.EditorFixture.releases(release)
    assert {:ok, %{}} = Releases.decode(%{"version" => 1, "targets" => %{}})

    for value <- [
          nil,
          release,
          %{},
          %{"version" => 2, "targets" => %{}},
          Map.put(valid, "extra", true),
          put_in(valid, ["targets", "linux-arm64"], release),
          put_in(valid, ["targets", "LINUX-X64"], release),
          put_in(valid, ["targets", "win32-x64"], release),
          put_in(valid, ["targets", "linux-x64", "protocol"], 2),
          put_in(valid, ["targets", "linux-x64", "release"], String.duplicate("A", 64)),
          put_in(valid, ["targets", "linux-x64", "extra"], true),
          put_in(valid, ["targets", "linux-x64"], nil)
        ] do
      assert {:error, :invalid_editor_releases} = Releases.decode(value)
    end
  end

  @spec descriptor(String.t(), String.t()) :: wire_descriptor()
  defp descriptor(commit, release),
    do: %{"protocol" => 1, "commit" => commit, "release" => release}

  @spec different_digest(String.t()) :: String.t()
  defp different_digest("0" <> rest), do: "1" <> rest
  defp different_digest(<<_first, rest::binary>>), do: "0" <> rest
end
