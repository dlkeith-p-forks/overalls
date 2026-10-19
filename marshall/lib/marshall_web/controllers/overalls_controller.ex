defmodule MarshallWeb.OverallsController do
  use MarshallWeb, :controller

  @targets ~w(linux-amd64 linux-arm64 darwin-amd64 darwin-arm64 windows-amd64)

  # @cc [owner:ghuntley,label:security] public-overalls-artifacts
  # Public responses MUST serve only the five immutable package artifacts
  # (Linux, macOS and Windows workstations) and their digest metadata from the
  # operator selected Nix store path.
  @spec artifact(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def artifact(conn, %{"target" => target}) when target in @targets do
    with {:ok, root} <- release_root(),
         path = Path.join([root, "bin", target]),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         true <- size > 0 and size <= 104_857_600 do
      conn
      |> put_resp_header("cache-control", "public, max-age=300")
      |> put_resp_content_type("application/octet-stream")
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, dgettext("downloads", "Unavailable") <> "\n")
    end
  end

  def artifact(conn, _), do: send_resp(conn, 404, dgettext("downloads", "Unavailable") <> "\n")

  @spec manifest(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def manifest(conn, _params) do
    with {:ok, root} <- release_root(),
         {:ok, bytes} <- File.read(Path.join(root, "manifest.json")),
         true <- byte_size(bytes) <= 16_384 do
      conn
      |> put_resp_header("cache-control", "public, max-age=300")
      |> put_resp_content_type("application/json")
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, dgettext("downloads", "Unavailable") <> "\n")
    end
  end

  @spec checksum(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def checksum(conn, %{"target" => target}) when target in @targets do
    with {:ok, root} <- release_root(),
         {:ok, bytes} <- File.read(Path.join(root, "manifest.json")),
         {:ok, %{"artifacts" => artifacts}} <- Jason.decode(bytes),
         %{"sha256" => digest} <- artifacts[target],
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
      conn |> put_resp_content_type("text/plain") |> send_resp(200, digest <> "\n")
    else
      _ -> send_resp(conn, 404, dgettext("downloads", "Unavailable") <> "\n")
    end
  end

  def checksum(conn, _), do: send_resp(conn, 404, dgettext("downloads", "Unavailable") <> "\n")

  @spec install(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def install(conn, _params), do: send_installer(conn, :shell, "text/x-shellscript")

  @spec install_powershell(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def install_powershell(conn, _params), do: send_installer(conn, :powershell, "text/plain")

  @spec send_installer(Plug.Conn.t(), MarshallWeb.OverallsInstaller.kind(), binary()) ::
          Plug.Conn.t()
  defp send_installer(conn, kind, content_type) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    host = URI.parse(MarshallWeb.Endpoint.url()).host
    policy = Application.get_env(:marshall, :ssh_host_trust)

    case MarshallWeb.OverallsInstaller.render(host, policy, kind) do
      {:ok, script} ->
        conn |> put_resp_content_type(content_type) |> send_resp(200, script)

      :error ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, dgettext("downloads", "Installer trust unavailable") <> "\n")
    end
  end

  @spec ssh_trust(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ssh_trust(conn, _) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Marshall.SSH.HostCertificates.policy() do
      {:ok, policy} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(policy))

      _ ->
        send_resp(conn, 503, dgettext("downloads", "SSH trust unavailable") <> "\n")
    end
  end

  @spec release_root() :: {:ok, binary()} | :error
  defp release_root do
    case System.get_env("OVERALLS_LYRA_RELEASE") do
      "/nix/store/" <> _ = path -> {:ok, path}
      _ -> :error
    end
  end
end
