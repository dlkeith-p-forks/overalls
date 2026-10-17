# Shared by scripts/check_conflict_markers.exs and its regression tests.
defmodule Overalls.ConflictMarkers do
  @moduledoc false
  @marker ~r/\A(<{7}|\|{7}|>{7})( |\z)/

  # @cc [owner:ghuntley,label:governance] no-committed-conflict-markers
  # Tracked text files MUST NOT contain merge-conflict markers. The check runs
  # at commit and merge-commit time and as a Nix check, because merge commits
  # skip ordinary pre-commit hooks and a marker in Nix breaks every evaluation.
  @spec violations([Path.t()]) :: [{Path.t(), pos_integer()}]
  def violations(paths) do
    Enum.flat_map(paths, fn path ->
      case File.read(path) do
        {:ok, bytes} -> if text?(bytes), do: scan(path, bytes), else: []
        {:error, _} -> []
      end
    end)
  end

  @spec scan(Path.t(), binary()) :: [{Path.t(), pos_integer()}]
  def scan(path, bytes) do
    bytes
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(@marker, String.trim_trailing(line, "\r")) end)
    |> Enum.map(fn {_, number} -> {path, number} end)
  end

  @spec text?(binary()) :: boolean()
  defp text?(bytes),
    do: not String.contains?(binary_part(bytes, 0, min(byte_size(bytes), 8000)), <<0>>)

  @spec tracked() :: [Path.t()]
  def tracked do
    {output, 0} = System.cmd("git", ["ls-files", "-z"])
    output |> String.split(<<0>>, trim: true)
  end
end
