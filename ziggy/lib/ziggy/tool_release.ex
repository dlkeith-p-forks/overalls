defmodule Ziggy.ToolRelease do
  @moduledoc "Startup-verified immutable managed-tool files; no guest-selected paths."
  @type artifact :: %{path: String.t(), digest: String.t(), size: pos_integer()}
  @type t :: %{generation: String.t(), artifacts: %{String.t() => artifact()}}

  # @cc [owner:ghuntley,label:security] ziggy-maintenance-file-custody
  # Startup MUST verify the closed release manifest and every bounded artifact's
  # size/hash. Only this immutable inventory may supply artifact paths. Request
  # digests are selectors, never paths or independent authorization.
  @spec load(String.t() | nil) :: {:ok, t() | nil} | {:error, :invalid_configuration}
  def load(nil), do: {:ok, nil}

  def load(root) when is_binary(root) do
    with true <- Path.type(root) == :absolute and Path.expand(root) == root,
         {:ok, %{type: :regular, size: size}} when size in 1..16_384 <-
           File.stat(Path.join(root, "manifest.json")),
         {:ok, bytes} <- File.read(Path.join(root, "manifest.json")),
         true <- byte_size(bytes) <= 16_384,
         {:ok, manifest} <- Jason.decode(bytes),
         {:ok, release} <- OverallsProtocol.GitHubTools.decode(manifest),
         {:ok, artifacts} <- verify(root, release) do
      {:ok, %{generation: release.generation, artifacts: artifacts}}
    else
      _ -> {:error, :invalid_configuration}
    end
  rescue
    _ -> {:error, :invalid_configuration}
  end

  def load(_), do: {:error, :invalid_configuration}

  @spec verify(String.t(), OverallsProtocol.GitHubTools.release()) ::
          {:ok, %{String.t() => artifact()}} | {:error, :invalid_configuration}
  defp verify(root, release) do
    release.platforms
    |> Map.values()
    |> List.flatten()
    |> Enum.reduce_while({:ok, %{}}, fn file, {:ok, acc} ->
      path = Path.join(root, file.path)

      with {:ok, %{type: :regular, size: size}} <- File.stat(path),
           true <- size == file.bytes,
           true <- digest(path) == file.sha256 do
        artifact = %{path: path, digest: file.sha256, size: file.bytes}
        {:cont, {:ok, Map.put(acc, file.sha256, artifact)}}
      else
        _ -> {:halt, {:error, :invalid_configuration}}
      end
    end)
  end

  @spec digest(String.t()) :: String.t()
  defp digest(path) do
    path
    |> File.stream!(65_536, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
