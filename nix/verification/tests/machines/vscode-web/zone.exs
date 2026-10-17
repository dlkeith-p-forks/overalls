defmodule EditorZonePreflight do
  @moduledoc "Native startup validation using the running gateway's private configuration."

  # @cc [owner:ghuntley,label:verification;security] editor-zone-real-startup
  # The current gateway configuration MUST first pass both real startup entry
  # points with the exact immutable editor release. Changing only its editor
  # zone to one DNS label MUST make both entry points reject it. The live config,
  # credentials and service MUST remain unchanged; their contents MUST NOT print.
  @spec run(String.t(), String.t()) :: :ok
  def run(path, expected_release) do
    checkpoint(:release_argument)
    true = Regex.match?(~r/\A[0-9a-f]{64}\z/, expected_release)
    checkpoint(:runtime_path)
    source = runtime_path(path)
    checkpoint(:live_config)
    {:ok, options} = Audi.Config.load(source)
    checkpoint(:descriptor)
    tls = Keyword.fetch!(options, :tls)
    "apps.example.test" = Keyword.fetch!(tls, :zone)
    %{descriptor: %{release: ^expected_release}} = Keyword.fetch!(tls, :editor_assets)
    checkpoint(:live_listener)
    {:ok, children} = Audi.Application.listener_children(source)
    true = children != []

    checkpoint(:clone_source)

    %{"tls" => %{"zone" => "apps.example.test"} = raw_tls} =
      value =
      source |> File.read!() |> JSON.decode!()

    changed = Map.put(value, "tls", Map.put(raw_tls, "zone", "apps"))
    clone = "/run/audi/editor-zone-preflight/one-label.json"

    try do
      checkpoint(:clone_write)
      File.write!(clone, JSON.encode!(changed), [:exclusive])
      File.chmod!(clone, 0o600)
      checkpoint(:clone_config_refusal)
      {:error, :invalid_runtime_configuration} = Audi.Config.load(clone)
      checkpoint(:clone_listener_refusal)
      {:error, :invalid_runtime_configuration} = Audi.Application.listener_children(clone)
      checkpoint(:live_revalidation)
      {:ok, _} = Audi.Config.load(source)
      :ok
    after
      File.rm(clone)
    end
  end

  @type stage ::
          :arguments
          | :release_argument
          | :runtime_path
          | :live_config
          | :descriptor
          | :live_listener
          | :clone_source
          | :clone_write
          | :clone_config_refusal
          | :clone_listener_refusal
          | :live_revalidation

  @spec checkpoint(stage()) :: :ok
  def checkpoint(stage) do
    Process.put(:editor_zone_preflight_stage, stage)
    :ok
  end

  @spec failure_stage() :: String.t()
  def failure_stage do
    case Process.get(:editor_zone_preflight_stage) do
      :arguments -> "arguments"
      :release_argument -> "release argument"
      :runtime_path -> "runtime path"
      :live_config -> "live config"
      :descriptor -> "descriptor"
      :live_listener -> "live listener"
      :clone_source -> "clone source"
      :clone_write -> "clone write"
      :clone_config_refusal -> "clone config refusal"
      :clone_listener_refusal -> "clone listener refusal"
      :live_revalidation -> "live revalidation"
      _ -> "unclassified"
    end
  end

  @spec runtime_path(String.t()) :: String.t()
  defp runtime_path(path) do
    true = is_binary(path) and byte_size(path) in 12..4096
    false = String.contains?(path, [<<0>>, "\n", "\r"])
    true = String.starts_with?(path, "/nix/store/") and Path.expand(path) == path
    path
  end
end

try do
  EditorZonePreflight.checkpoint(:arguments)
  [path, release] = System.argv()
  :ok = EditorZonePreflight.run(path, release)
  IO.puts("Editor native zone startup assertions passed")
rescue
  _ ->
    IO.puts(
      :stderr,
      "Editor native zone startup assertions failed at " <>
        EditorZonePreflight.failure_stage() <> "; private configuration withheld"
    )

    System.halt(1)
end
