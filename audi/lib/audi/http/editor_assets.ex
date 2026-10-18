defmodule Audi.HTTP.EditorAssets do
  @moduledoc "Immutable, release-bound webview bootstrap assets; no guest or browser authority."
  import Plug.Conn
  alias OverallsProtocol.{EditorName, EditorRelease}
  @relative "out/vs/workbench/contrib/webview/browser/pre"
  @files %{
    "index.html" => "text/html; charset=utf-8",
    "fake.html" => "text/html; charset=utf-8",
    "service-worker.js" => "text/javascript; charset=utf-8"
  }
  @targets ["linux-x64", "win32-x64"]
  @type t :: %{root: binary(), descriptor: EditorRelease.t()}
  @type registry :: %{optional(binary()) => t()}

  # @cc [owner:ghuntley,label:security;protocol] audi-editor-target-registry
  # Configuration MUST contain only the finite linux-x64/win32-x64 target map,
  # with independently validated immutable roots and distinct release IDs.
  # Unknown targets, malformed roots and ambiguous releases MUST refuse the
  # complete registry. The empty map disables assets without fallback.
  @spec load_registry(term()) :: {:ok, registry()} | {:error, :invalid_editor_assets}
  def load_registry(packages) when is_map(packages) and map_size(packages) <= 2 do
    Enum.reduce_while(packages, {:ok, %{}}, fn {target, root}, {:ok, assets} ->
      with true <- target in @targets,
           {:ok, asset} <- load(root),
           false <-
             Enum.any?(assets, fn {_, existing} ->
               existing.descriptor.release == asset.descriptor.release
             end) do
        {:cont, {:ok, Map.put(assets, target, asset)}}
      else
        _ -> {:halt, {:error, :invalid_editor_assets}}
      end
    end)
  end

  def load_registry(_), do: {:error, :invalid_editor_assets}

  # @cc [owner:ghuntley,label:security] audi-editor-immutable-assets
  # Asset configuration MUST be an immutable Nix store output with an exact
  # release descriptor and three regular bootstrap files. Requests MUST select
  # only those files at an exact configured release on canonical webview hash hosts;
  # no caller path, cookie or hash may select a filesystem root or guest relay.
  @spec load(term()) :: {:ok, t()} | {:error, :invalid_editor_assets}
  def load(root) when is_binary(root) and byte_size(root) <= 4096 do
    with true <- String.starts_with?(root, "/nix/store/") and Path.expand(root) == root,
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         {:ok, %File.Stat{type: :regular, size: size}} when size in 1..1024 <-
           File.lstat(Path.join(root, "overalls-editor-release.json")),
         {:ok, bytes} <- File.read(Path.join(root, "overalls-editor-release.json")),
         true <- byte_size(bytes) <= 1024,
         {:ok,
          %{"source_commit" => commit, "editor_protocol" => protocol, "release_id" => release} =
            value}
         when map_size(value) == 3 <- JSON.decode(bytes),
         {:ok, descriptor} <-
           EditorRelease.decode(%{
             "protocol" => protocol,
             "commit" => commit,
             "release" => release
           }),
         true <- Enum.all?(Map.keys(@files), &regular?(root, &1)) do
      {:ok, %{root: root, descriptor: descriptor}}
    else
      _ -> {:error, :invalid_editor_assets}
    end
  end

  def load(_), do: {:error, :invalid_editor_assets}

  @spec host?(term(), term()) :: boolean()
  def host?(host, zone) when is_binary(host) and is_binary(zone) do
    suffix = "." <> zone

    String.ends_with?(host, suffix) and
      EditorName.webview_label?(String.replace_suffix(host, suffix, ""))
  end

  def host?(_, _), do: false

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, options) do
    with true <- host?(conn.host, options[:zone]),
         true <- conn.method in ["GET", "HEAD"],
         ["", "code-assets", release, relative] <- String.split(conn.request_path, "/", parts: 4),
         %{root: root} <- asset_for_release(options[:editor_assets], release),
         prefix = @relative <> "/",
         true <- String.starts_with?(relative, prefix),
         filename = String.replace_prefix(relative, prefix, ""),
         type when is_binary(type) <- @files[filename],
         true <- regular?(root, filename) do
      conn =
        conn
        |> delete_resp_header("connection")
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_header("content-type", type)
        |> put_resp_header("x-content-type-options", "nosniff")

      if conn.method == "HEAD",
        do: send_resp(conn, 200, ""),
        else: send_file(conn, 200, Path.join([root, @relative, filename]))
    else
      _ -> send_resp(conn, 404, "Unavailable\n")
    end
  end

  @spec asset_for_release(term(), binary()) :: t() | nil
  defp asset_for_release(assets, release) when is_map(assets) and map_size(assets) in 1..2 do
    Enum.find_value(assets, fn
      {target, %{descriptor: %{release: ^release}} = asset} when target in @targets -> asset
      _ -> nil
    end)
  end

  defp asset_for_release(_, _), do: nil

  defp regular?(root, filename) do
    case File.lstat(Path.join([root, @relative, filename])) do
      {:ok, %File.Stat{type: :regular, size: size, mode: mode}} ->
        size in 1..1_048_576 and Bitwise.band(mode, 0o222) == 0

      _ ->
        false
    end
  end
end
