defmodule OverallsProtocol.ExecutorBootstrap do
  @moduledoc "Closed public executor artifact inventory for managed-tool bootstrap."
  alias OverallsProtocol.GitHubTools
  @platforms ~w(linux-amd64 windows-amd64 freebsd-amd64 illumos-amd64)
  @type artifact :: %{path: String.t(), sha256: String.t(), bytes: pos_integer()}
  @type release :: %{version: 1, platforms: %{String.t() => artifact()}}

  # @cc [owner:ghuntley,label:security;protocol] executor-bootstrap-closed-inventory
  # Bootstrap inventories MUST contain exactly the four reviewed platforms,
  # fixed relative executable paths and bounded, digest-bound public bytes.
  @spec decode(term()) :: {:ok, release()} | {:error, :invalid_executor_bootstrap}
  def decode(%{"version" => 1, "platforms" => platforms} = value)
      when map_size(value) == 2 and is_map(platforms) do
    if Enum.sort(Map.keys(platforms)) == Enum.sort(@platforms) do
      Enum.reduce_while(@platforms, {:ok, %{}}, fn platform, {:ok, acc} ->
        path = platform <> if(platform == "windows-amd64", do: "/executor.exe", else: "/executor")

        case platforms[platform] do
          %{"path" => ^path, "sha256" => digest, "bytes" => bytes} = file
          when map_size(file) == 3 and is_integer(bytes) and bytes in 1..104_857_600 ->
            if GitHubTools.digest?(digest),
              do:
                {:cont,
                 {:ok, Map.put(acc, platform, %{path: path, sha256: digest, bytes: bytes})}},
              else: {:halt, {:error, :invalid_executor_bootstrap}}

          _ ->
            {:halt, {:error, :invalid_executor_bootstrap}}
        end
      end)
      |> case do
        {:ok, parsed} -> {:ok, %{version: 1, platforms: parsed}}
        error -> error
      end
    else
      {:error, :invalid_executor_bootstrap}
    end
  end

  def decode(_), do: {:error, :invalid_executor_bootstrap}
end
