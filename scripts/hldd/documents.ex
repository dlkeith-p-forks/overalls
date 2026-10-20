defmodule Overalls.HLDDDocuments do
  @moduledoc "Batched YAML/frontmatter documents using the pinned safe YAML parser."
  @type document :: %{String.t() => term()}

  @spec read([String.t()]) :: [document()]
  def read([]), do: []
  def read(paths), do: call("read", Enum.map(paths, &%{"path" => &1}))

  @spec write([document()]) :: :ok
  def write([]), do: :ok

  def write(entries) do
    [] = call("write", entries)
    :ok
  end

  @spec call(String.t(), [document()]) :: [document()]
  defp call(operation, entries) do
    directory =
      Path.join(System.tmp_dir!(), "hldd-io-" <> Base.url_encode64(:crypto.strong_rand_bytes(18)))

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    input = Path.join(directory, "request.json")

    try do
      File.write!(input, JSON.encode!(%{"operation" => operation, "entries" => entries}))
      python = System.get_env("OVERALLS_HLDD_PYTHON") || "python3"

      case System.cmd(python, [Path.join(__DIR__, "yaml_io.py"), input], stderr_to_stdout: true) do
        {output, 0} -> JSON.decode!(output)
        {output, _} -> raise("HLDD YAML IO failed: " <> output)
      end
    after
      File.rm_rf!(directory)
    end
  end

  @spec collection(String.t(), String.t()) :: [map()]
  def collection(directory, identity) do
    paths = paths(directory, ".yaml")
    if paths == [], do: raise("missing YAML collection: #{directory}")

    Enum.zip(paths, read(paths))
    |> Enum.map(fn {path, %{"data" => data}} ->
      unless is_map(data) and data[identity] == Path.basename(path, ".yaml"),
        do: raise("YAML filename must match #{identity}: #{path}")

      data
    end)
  end

  @doc "Enumerate only regular documents; symlinks and unexpected extensions fail closed."
  @spec paths(String.t(), String.t()) :: [String.t()]
  def paths(directory, extension) do
    if File.exists?(directory) do
      unless File.lstat!(directory).type == :directory,
        do: raise("invalid document directory: #{directory}")

      directory
      |> File.ls!()
      |> Enum.sort()
      |> Enum.flat_map(fn name ->
        path = Path.join(directory, name)

        case File.lstat!(path).type do
          :directory ->
            paths(path, extension)

          :regular ->
            unless String.ends_with?(path, extension), do: raise("unexpected document: #{path}")
            [path]

          _ ->
            raise("document must be a regular file: #{path}")
        end
      end)
    else
      []
    end
  end
end
