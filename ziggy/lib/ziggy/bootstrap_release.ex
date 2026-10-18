defmodule Ziggy.BootstrapRelease do
  @moduledoc "Verified executor bytes for bounded retained-machine bootstrap."
  @type t :: %{artifacts: %{String.t() => Ziggy.ToolRelease.artifact()}}

  # @cc [owner:ghuntley,label:security] bootstrap-artifact-inventory
  # Only closed manifest paths whose complete size and digest verify at startup
  # may supply executable bytes. Guest input MUST select only a digest and MUST
  # obtain current Marshall attempt authority before any bytes are delivered.
  @spec load(String.t() | nil) :: {:ok, t() | nil} | {:error, :invalid_configuration}
  def load(nil), do: {:ok, nil}

  def load(root) when is_binary(root) do
    with true <- Path.type(root) == :absolute and Path.expand(root) == root,
         {:ok, %{type: :regular, size: size}} when size in 1..16_384 <-
           File.stat(Path.join(root, "manifest.json")),
         {:ok, bytes} <- File.read(Path.join(root, "manifest.json")),
         true <- byte_size(bytes) <= 16_384,
         {:ok, manifest} <- Jason.decode(bytes),
         {:ok, release} <- OverallsProtocol.ExecutorBootstrap.decode(manifest),
         {:ok, artifacts} <- verify(root, release.platforms) do
      {:ok, %{artifacts: artifacts}}
    else
      _ -> {:error, :invalid_configuration}
    end
  rescue
    _ -> {:error, :invalid_configuration}
  end

  def load(_), do: {:error, :invalid_configuration}

  @spec verify(String.t(), %{
          String.t() => %{path: String.t(), sha256: String.t(), bytes: pos_integer()}
        }) ::
          {:ok, %{String.t() => Ziggy.ToolRelease.artifact()}} | {:error, :invalid_configuration}
  defp verify(root, platforms) do
    Enum.reduce_while(platforms, {:ok, %{}}, fn {_platform, file}, {:ok, acc} ->
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
