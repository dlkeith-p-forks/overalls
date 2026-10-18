defmodule Overalls.RequestAccounting.QualityMarkerTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Overalls.RequestAccounting.QualityMarker

  defp with_temp_directory(fun) when is_function(fun, 1) do
    directory = Path.join(System.tmp_dir!(), "slo-marker-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    try do
      fun.(directory)
    after
      File.rm_rf!(directory)
    end
  end

  property "quality histories persist exactly without carrying request data" do
    qualities =
      draw(
        "qualities",
        list_of(member_of([:running, :gap, :clean]), min_length: 1, max_length: 30)
      )

    with_temp_directory(fn directory ->
      for quality <- qualities do
        assert :ok = QualityMarker.write(directory, quality)
        assert {:ok, ^quality} = QualityMarker.read(directory)
        assert {:ok, stat} = File.stat(Path.join(directory, "quality"))
        assert Bitwise.band(stat.mode, 0o777) == 0o600
      end
    end)
  end

  test "corrupt marker refuses replacement rather than inventing clean history" do
    with_temp_directory(fn directory ->
      assert :ok = QualityMarker.write(directory, :running)
      File.write!(Path.join(directory, "quality"), "corrupt")
      assert {:error, :storage} = QualityMarker.write(directory, :clean)
      assert File.read!(Path.join(directory, "quality")) == "corrupt"
    end)
  end

  test "symlinks, hardlinks and public directories refuse custody" do
    with_temp_directory(fn directory ->
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
    end)
  end
end
