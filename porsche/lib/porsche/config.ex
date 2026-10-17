defmodule Porsche.Config do
  @moduledoc "Closed, operator-owned startup configuration with a separate private gateway credential."
  import Bitwise
  alias Porsche.Client

  @fields ~w(version control_plane public_origin credential_file host_key_dir bind port cacertfile status_socket)

  # @cc [owner:ghuntley,label:security] porsche-configuration-secret-custody
  # Startup MUST reject unknown fields, inline credentials, non-HTTPS origins,
  # unsafe config/credential paths and invalid listener bounds. Gateway and host
  # private-key files MUST be single-link regular files owned by this service,
  # mode 0400 or 0600, under trusted non-symlink directories. Errors MUST be fixed
  # values without file contents, paths, credentials or parser exceptions.
  @spec load(term()) :: {:ok, keyword()} | {:error, :invalid_runtime_configuration}
  def load(path) do
    with {:ok, encoded} <- read(path, :config, 16_384),
         {:ok,
          %{
            "version" => 1,
            "control_plane" => origin,
            "public_origin" => public,
            "credential_file" => credential,
            "host_key_dir" => keys
          } = value} <- JSON.decode(encoded),
         true <- Map.keys(value) -- @fields == [],
         {:ok, token} <- read(credential, :secret, 256),
         token =
           if(String.ends_with?(token, "\n"),
             do: binary_part(token, 0, byte_size(token) - 1),
             else: token
           ),
         {:ok, client} <- Client.new(origin, token, cacertfile: value["cacertfile"]),
         {:ok, _} <- Client.new(public, token),
         :ok <- certificate(value["cacertfile"]),
         true <- canonical_path?(keys),
         {:ok, %File.Stat{type: :directory, uid: owner, mode: mode}} <- File.lstat(keys),
         true <- owner == uid() and band(mode, 0o777) == 0o700,
         {:ok, _} <- read(Path.join(keys, "ssh_host_ed25519_key"), :secret, 16_384),
         port = Map.get(value, "port", 22),
         true <- is_integer(port) and port in 1..65_535,
         bind = Map.get(value, "bind", "0.0.0.0"),
         true <- is_binary(bind) and byte_size(bind) <= 45,
         {:ok, address} <- :inet.parse_ipv4strict_address(String.to_charlist(bind)),
         true <- to_string(:inet.ntoa(address)) == bind,
         :ok <- status_socket(value["status_socket"]) do
      {:ok,
       [
         client: client,
         public_origin: String.trim_trailing(public, "/"),
         host_key_dir: keys,
         port: port,
         bind: address,
         name: Porsche.Listener
       ] ++ if(value["status_socket"], do: [status_socket: value["status_socket"]], else: [])}
    else
      _ -> {:error, :invalid_runtime_configuration}
    end
  rescue
    _ -> {:error, :invalid_runtime_configuration}
  end

  # @cc [owner:ghuntley,label:security] porsche-status-private-directory
  # A configured status socket MUST use a canonical absolute path under trusted
  # nonsymlink ancestors and a service-owned mode-0700 immediate directory.
  @spec status_socket(term()) :: :ok | :error
  def status_socket(nil), do: :ok

  def status_socket(path) do
    with true <- canonical_path?(path),
         :ok <- parents(Path.dirname(path)),
         {:ok, %File.Stat{type: :directory, uid: owner, mode: mode}} <-
           File.lstat(Path.dirname(path)),
         true <- owner == uid() and band(mode, 0o777) == 0o700 do
      :ok
    else
      _ -> :error
    end
  end

  defp read(path, kind, maximum) do
    with true <- canonical_path?(path),
         :ok <- parents(Path.dirname(path)),
         {:ok, %File.Stat{type: :regular, size: size} = stat} <- File.lstat(path),
         true <- size in 1..maximum and permissions?(stat, kind),
         {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= maximum <-
           File.open(path, [:read, :binary], &IO.binread(&1, maximum + 1)) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp permissions?(stat, :secret),
    do: stat.uid == uid() and stat.links == 1 and band(stat.mode, 0o777) in [0o400, 0o600]

  defp permissions?(stat, :config),
    do: stat.uid in [0, uid()] and band(stat.mode, 0o022) == 0

  defp parents("/"), do: :ok

  defp parents(path) do
    with {:ok, %File.Stat{type: :directory, uid: owner, mode: mode}} <- File.lstat(path),
         true <- owner in [0, uid()],
         true <- band(mode, 0o022) == 0 or band(mode, 0o1000) != 0 do
      parents(Path.dirname(path))
    else
      _ -> :error
    end
  end

  defp canonical_path?(path) when is_binary(path) and byte_size(path) in 1..4096,
    do:
      String.valid?(path) and Path.type(path) == :absolute and Path.expand(path) == path and
        not String.contains?(path, [<<0>>, "\n", "\r"])

  defp canonical_path?(_), do: false

  defp certificate(nil), do: :ok

  defp certificate(path) do
    with {:ok, bytes} <- read(path, :config, 1_048_576),
         entries when is_list(entries) and entries != [] <- :public_key.pem_decode(bytes),
         true <-
           Enum.all?(entries, fn
             {:Certificate, der, :not_encrypted} ->
               match?({:OTPCertificate, _, _, _}, :public_key.pkix_decode_cert(der, :otp))

             _ ->
               false
           end) do
      :ok
    else
      _ -> :error
    end
  end

  defp uid do
    {:ok, stat} = File.stat("/proc/self")
    stat.uid
  end
end
