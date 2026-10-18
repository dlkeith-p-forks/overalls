defmodule Marshall.Operations.GitHubTools do
  @moduledoc "Validated immutable tool release inventory, without caller-selected paths."
  alias OverallsProtocol.GitHubTools

  @type release :: GitHubTools.release()

  # @cc [owner:ghuntley,label:security] github-tools-inventory-custody
  # Only the operator-configured absolute manifest may supply tool identities.
  # Reading it MUST validate its closed schema and every immutable artifact's
  # regular-file size and SHA256 before returning the release. Caller input
  # MUST NOT choose paths, versions or download origins. Failure is closed and
  # MUST NOT reflect file contents or paths in diagnostics.
  @spec load() :: {:ok, release()} | {:error, :unavailable}
  def load do
    case Application.get_env(:marshall, :github_tools_manifest_file) do
      "/nix/store/" <> _ = path -> cached(path)
      path when is_binary(path) -> load(path)
      _ -> {:error, :unavailable}
    end
  end

  @spec cached(String.t()) :: {:ok, release()} | {:error, :unavailable}
  defp cached(path) do
    key = {__MODULE__, path}

    case :persistent_term.get(key, nil) do
      nil ->
        case load(path) do
          {:ok, release} = result ->
            :persistent_term.put(key, release)
            result

          error ->
            error
        end

      release ->
        {:ok, release}
    end
  end

  @spec load(String.t()) :: {:ok, release()} | {:error, :unavailable}
  def load(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, %{type: :regular, size: size}} when size in 1..16_384 <- File.stat(path),
         {:ok, contents} <- File.read(path),
         true <- byte_size(contents) <= 16_384,
         {:ok, manifest} <- JSON.decode(contents),
         {:ok, release} <- GitHubTools.decode(manifest),
         true <- artifacts_match?(Path.dirname(path), release) do
      {:ok, release}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @spec artifacts_match?(String.t(), release()) :: boolean()
  defp artifacts_match?(root, release) do
    release.platforms
    |> Map.values()
    |> List.flatten()
    |> Enum.all?(fn file ->
      path = Path.join(root, file.path)

      with {:ok, %{type: :regular, size: size}} <- File.stat(path),
           true <- size == file.bytes do
        hash =
          path
          |> File.stream!(65_536, [])
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        hash == file.sha256
      else
        _ -> false
      end
    end)
  end
end
