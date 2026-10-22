defmodule Marshall.Artifacts.Manifest do
  @moduledoc """
  Applies a publish's file changes to the previous version's file map.

  Sent paths are added or replaced, `nil` removes a path, and omitted paths are
  kept. The page path is managed separately and cannot be removed here.
  """
  alias Marshall.Artifacts.Paths

  @type entry :: %{
          required(:sha256) => String.t(),
          required(:bytes) => non_neg_integer(),
          required(:content_type) => String.t(),
          optional(:data) => binary()
        }
  @type files :: %{String.t() => entry()}
  @type change :: entry() | nil

  # @cc [owner:ghuntley,label:correctness] artifact-manifest-semantics
  # The next file map MUST equal the previous map with every sent path replaced
  # or added, every `nil` path removed and every omitted path kept. Two sent
  # keys that normalize to the same path, or a change to the page path, refuse
  # the whole publish.
  @spec apply(files(), %{String.t() => change()}) ::
          {:ok, files()} | {:error, :invalid_path | :manifest_conflict}
  def apply(previous, changes) when is_map(previous) and is_map(changes) do
    Enum.reduce_while(changes, {:ok, previous, MapSet.new()}, fn {raw, change},
                                                                 {:ok, acc, seen} ->
      with {:ok, path} <- Paths.normalize(raw),
           false <- path == Paths.page(),
           false <- MapSet.member?(seen, path) do
        next = if is_nil(change), do: Map.delete(acc, path), else: Map.put(acc, path, change)
        {:cont, {:ok, next, MapSet.put(seen, path)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        true -> {:halt, {:error, :manifest_conflict}}
      end
    end)
    |> case do
      {:ok, files, _} -> {:ok, files}
      error -> error
    end
  end

  @doc "Total bytes and file count of a file map plus the page."
  @spec totals(files(), non_neg_integer()) :: {non_neg_integer(), pos_integer()}
  def totals(files, page_bytes) do
    {Enum.reduce(files, page_bytes, fn {_, entry}, sum -> sum + entry.bytes end),
     map_size(files) + 1}
  end
end
