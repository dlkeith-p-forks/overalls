defmodule MarshallWeb.MarvinDownloadController do
  use MarshallWeb, :controller

  @artifacts ~w(chrome.zip firefox.xpi)
  @maximum_artifact_bytes 10_485_760
  @maximum_manifest_bytes 16_384

  @spec chrome(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def chrome(conn, _params), do: artifact(conn, %{"artifact" => "chrome.zip"})

  @spec firefox(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def firefox(conn, _params), do: artifact(conn, %{"artifact" => "firefox.xpi"})

  # @cc [owner:ghuntley,label:security] public-marvin-download-allowlist
  # Public downloads MUST serve only chrome.zip and firefox.xpi from the
  # configured immutable Nix package. User input MUST NOT select a filesystem
  # path. Symlinked release roots or bin parents, absent, oversized or non-regular
  # files, invalid manifests and declared length mismatches MUST return 404.
  @spec artifact(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def artifact(conn, %{"artifact" => artifact}) when artifact in @artifacts do
    with {:ok, root} <- release_root(),
         {:ok, _bytes, %{"artifacts" => artifacts}} <- release_manifest(root),
         %{"size" => expected_size} <- Map.get(artifacts, artifact),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.join(root, "bin")),
         path = Path.join([root, "bin", artifact]),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size == expected_size do
      conn
      |> cache()
      |> put_resp_content_type(content_type(artifact), nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{artifact}"))
      |> send_file(200, path)
    else
      _ -> unavailable(conn)
    end
  end

  def artifact(conn, _), do: unavailable(conn)

  @spec manifest(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def manifest(conn, _params) do
    with {:ok, root} <- release_root(),
         {:ok, bytes, _manifest} <- release_manifest(root) do
      conn |> cache() |> put_resp_content_type("application/json") |> send_resp(200, bytes)
    else
      _ -> unavailable(conn)
    end
  end

  @spec checksum(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def checksum(conn, %{"artifact" => artifact}) when artifact in @artifacts do
    with {:ok, root} <- release_root(),
         {:ok, _bytes, %{"artifacts" => artifacts}} <- release_manifest(root),
         %{"sha256" => digest} <- Map.get(artifacts, artifact) do
      conn |> cache() |> put_resp_content_type("text/plain") |> send_resp(200, digest <> "\n")
    else
      _ -> unavailable(conn)
    end
  end

  def checksum(conn, _), do: unavailable(conn)

  @spec release_root() :: {:ok, String.t()} | :error
  defp release_root do
    case System.get_env("OVERALLS_MARVIN_RELEASE") do
      "/nix/store/" <> _ = path ->
        with true <- Regex.match?(~r/\A\/nix\/store\/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+\z/, path),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
          {:ok, path}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @spec release_manifest(String.t()) :: {:ok, binary(), map()} | :error
  defp release_manifest(root) do
    path = Path.join(root, "manifest.json")

    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size > 0 and size <= @maximum_manifest_bytes,
         {:ok, bytes} <- File.read(path),
         {:ok, %{"version" => 1, "unsigned" => true, "artifacts" => artifacts} = manifest} <-
           Jason.decode(bytes),
         true <- valid_artifacts?(artifacts) do
      {:ok, bytes, manifest}
    else
      _ -> :error
    end
  end

  @spec valid_artifacts?(term()) :: boolean()
  defp valid_artifacts?(artifacts) when is_map(artifacts) do
    Enum.sort(Map.keys(artifacts)) == @artifacts and
      Enum.all?(artifacts, fn
        {_name, %{"sha256" => digest, "size" => size}} ->
          is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) and
            is_integer(size) and size > 0 and size <= @maximum_artifact_bytes

        _ ->
          false
      end)
  end

  defp valid_artifacts?(_), do: false

  @spec content_type(String.t()) :: String.t()
  defp content_type("chrome.zip"), do: "application/zip"
  defp content_type("firefox.xpi"), do: "application/x-xpinstall"

  @spec cache(Plug.Conn.t()) :: Plug.Conn.t()
  defp cache(conn), do: put_resp_header(conn, "cache-control", "public, max-age=300")

  @spec unavailable(Plug.Conn.t()) :: Plug.Conn.t()
  defp unavailable(conn), do: send_resp(conn, 404, dgettext("downloads", "Unavailable") <> "\n")
end
