defmodule Overalls.RequestAccounting.QualityMarkerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Overalls.RequestAccounting.QualityMarker

  setup do
    directory = Path.join(System.tmp_dir!(), "slo-marker-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  property "quality histories persist exactly without carrying request data", %{
    directory: directory
  } do
    check all(
            qualities <-
              list_of(member_of([:running, :gap, :clean]), min_length: 1, max_length: 30),
            max_runs: 32
          ) do
      for quality <- qualities do
        assert :ok = QualityMarker.write(directory, quality)
        assert {:ok, ^quality} = QualityMarker.read(directory)
        assert {:ok, stat} = File.stat(Path.join(directory, "quality"))
        assert Bitwise.band(stat.mode, 0o777) == 0o600
      end
    end
  end

  test "corrupt marker refuses replacement rather than inventing clean history", %{
    directory: directory
  } do
    assert :ok = QualityMarker.write(directory, :running)
    File.write!(Path.join(directory, "quality"), "corrupt")
    assert {:error, :storage} = QualityMarker.write(directory, :clean)
    assert File.read!(Path.join(directory, "quality")) == "corrupt"
  end

  test "symlinks, hardlinks and public directories refuse custody", %{directory: directory} do
    assert :ok = QualityMarker.write(directory, :gap)
    quality = Path.join(directory, "quality")
    copied = Path.join(directory, "other")
    File.ln!(quality, copied)
    assert {:error, :storage} = QualityMarker.write(directory, :clean)
    File.rm!(copied)
    File.rename!(quality, copied)
    File.ln_s!(copied, quality)
    assert {:error, :storage} = QualityMarker.write(directory, :clean)
    File.rm!(quality)
    File.rename!(copied, quality)
    File.chmod!(directory, 0o750)
    assert {:error, :storage} = QualityMarker.write(directory, :clean)
  end
end
