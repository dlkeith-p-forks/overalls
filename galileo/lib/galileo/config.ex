defmodule Galileo.Config do
  @moduledoc "Strict public configuration plus private systemd credential paths."
  @spec load(binary()) :: {:ok, map()} | {:error, :invalid_configuration}
  def load(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= 16_384 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(bytes),
         true <-
           Enum.sort(Map.keys(value)) ==
             Enum.sort(~w(version host_id control_plane ca_file credential_file socket)),
         1 <- value["version"],
         true <- OverallsProtocol.uuid?(value["host_id"]),
         %URI{
           scheme: "https",
           host: host,
           userinfo: nil,
           query: nil,
           fragment: nil,
           path: uri_path
         }
         when is_binary(host) and uri_path in [nil, ""] <- URI.parse(value["control_plane"]),
         true <- private_path?(value["socket"]),
         true <- byte_size(value["socket"]) <= 107,
         {:ok, token} <- Galileo.Credential.read(value["credential_file"]),
         true <- byte_size(token) == 80,
         true <- is_binary(value["ca_file"]) and File.regular?(value["ca_file"]) do
      {:ok,
       %{
         host_id: value["host_id"],
         socket: value["socket"],
         control: %{
           client: Galileo.ControlClient,
           origin: value["control_plane"],
           token: token,
           ca_file: value["ca_file"]
         }
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  rescue
    _ -> {:error, :invalid_configuration}
  end

  defp private_path?(value) when is_binary(value),
    do:
      Path.type(value) == :absolute and Path.expand(value) == value and
        not String.starts_with?(value, "/nix/store/")

  defp private_path?(_), do: false
end
