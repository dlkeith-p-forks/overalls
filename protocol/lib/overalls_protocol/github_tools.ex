defmodule OverallsProtocol.GitHubTools do
  @moduledoc "Closed immutable managed GitHub tool release manifests."

  @platforms ~w(linux-amd64 windows-amd64 freebsd-amd64 illumos-amd64)
  @names ~w(gh git-lfs github.gitconfig)
  @type platform :: String.t()
  @type file :: %{name: String.t(), path: String.t(), sha256: String.t(), bytes: pos_integer()}
  @type release :: %{
          generation: String.t(),
          configuration_sha256: String.t(),
          platforms: %{platform() => [file()]}
        }
  @type json :: String.t() | non_neg_integer() | [json()] | %{String.t() => json()}

  @spec platforms() :: [platform()]
  def platforms, do: @platforms

  @spec digest?(term()) :: boolean()
  def digest?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  def digest?(_), do: false

  # @cc [owner:ghuntley,label:security;protocol] github-tools-immutable-release
  # A manifest MUST contain only known platforms and exactly the two executable
  # names and managed Git configuration for each platform. All paths MUST be the
  # fixed platform-local names, sizes bounded, and configuration hashes equal.
  # The generation MUST authenticate the complete canonical manifest excluding
  # generation itself. A manifest is a content identity, never VM authority.
  @spec decode(term()) :: {:ok, release()} | {:error, :invalid_github_tools}
  def decode(
        %{
          "version" => 1,
          "generation" => generation,
          "configuration_sha256" => configuration,
          "platforms" => platforms
        } = input
      )
      when map_size(input) == 4 and is_map(platforms) and map_size(platforms) in 1..4 do
    with true <- digest?(generation) and digest?(configuration),
         true <- Enum.all?(Map.keys(platforms), &(&1 in @platforms)),
         {:ok, decoded} <- decode_platforms(platforms, configuration),
         true <- generation == generation(Map.delete(input, "generation")) do
      {:ok, %{generation: generation, configuration_sha256: configuration, platforms: decoded}}
    else
      _ -> {:error, :invalid_github_tools}
    end
  end

  def decode(_), do: {:error, :invalid_github_tools}

  @doc "Hash a trusted typed manifest body using compact sorted-key JSON."
  @spec generation(%{String.t() => json()}) :: String.t()
  def generation(body) do
    :crypto.hash(:sha256, canonical(body)) |> Base.encode16(case: :lower)
  end

  @spec decode_platforms(map(), String.t()) ::
          {:ok, %{platform() => [file()]}} | {:error, :invalid_github_tools}
  defp decode_platforms(platforms, configuration) do
    Enum.reduce_while(platforms, {:ok, %{}}, fn {platform, value}, {:ok, acc} ->
      case decode_files(platform, value, configuration) do
        {:ok, files} -> {:cont, {:ok, Map.put(acc, platform, files)}}
        _ -> {:halt, {:error, :invalid_github_tools}}
      end
    end)
  end

  @spec decode_files(platform(), term(), String.t()) ::
          {:ok, [file()]} | {:error, :invalid_github_tools}
  defp decode_files(platform, %{"files" => files} = value, configuration)
       when map_size(value) == 1 and is_list(files) and length(files) == 3 do
    Enum.reduce_while(files, {:ok, []}, fn value, {:ok, acc} ->
      case decode_file(platform, value, configuration) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        _ -> {:halt, {:error, :invalid_github_tools}}
      end
    end)
    |> case do
      {:ok, decoded} ->
        if Enum.sort(Enum.map(decoded, & &1.name)) == Enum.sort(@names),
          do: {:ok, Enum.sort_by(decoded, & &1.name)},
          else: {:error, :invalid_github_tools}

      error ->
        error
    end
  end

  defp decode_files(_, _, _), do: {:error, :invalid_github_tools}

  @spec decode_file(platform(), term(), String.t()) ::
          {:ok, file()} | {:error, :invalid_github_tools}
  defp decode_file(
         platform,
         %{"name" => name, "path" => path, "sha256" => digest, "bytes" => bytes} = value,
         config
       )
       when map_size(value) == 4 and name in @names and is_integer(bytes) and bytes > 0 do
    suffix = if platform == "windows-amd64" and name != "github.gitconfig", do: ".exe", else: ""
    maximum = if name == "github.gitconfig", do: 16_384, else: 104_857_600

    if digest?(digest) and bytes <= maximum and path == platform <> "/" <> name <> suffix and
         (name != "github.gitconfig" or digest == config) do
      {:ok, %{name: name, path: path, sha256: digest, bytes: bytes}}
    else
      {:error, :invalid_github_tools}
    end
  end

  defp decode_file(_, _, _), do: {:error, :invalid_github_tools}

  @spec canonical(json()) :: iodata()
  defp canonical(value) when is_map(value) do
    members =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, val} ->
        [JSON.encode!(key), ":", canonical(val)]
      end)

    ["{", Enum.intersperse(members, ","), "}"]
  end

  defp canonical(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &canonical/1), ","), "]"]

  defp canonical(value), do: JSON.encode!(value)
end
