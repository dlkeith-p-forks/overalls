defmodule Peach.Config do
  @moduledoc "Strict public configuration plus private systemd credential paths."

  @type t :: %{
          host_id: binary(),
          socket: binary(),
          control: Peach.Control.t()
        }

  @keys ~w(version host_id control_plane ca_file credential_file socket)

  @spec load(binary()) :: {:ok, t()} | {:error, :invalid_configuration}
  def load(path) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= 16_384 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(bytes),
         true <- Enum.sort(Map.keys(value)) == Enum.sort(@keys),
         1 <- value["version"],
         true <- OverallsProtocol.uuid?(value["host_id"]),
         true <- https_origin?(value["control_plane"]),
         true <- private_path?(value["socket"]) and byte_size(value["socket"]) <= 107,
         true <- private_path?(value["ca_file"]) and File.regular?(value["ca_file"]),
         {:ok, token} <- Peach.Credential.read(value["credential_file"]),
         true <- byte_size(token) == 80 do
      {:ok,
       %{
         host_id: value["host_id"],
         socket: value["socket"],
         control: %{
           client: Peach.ControlClient,
           origin: value["control_plane"],
           token: token,
           host_id: value["host_id"],
           ca_file: value["ca_file"]
         }
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  rescue
    _ -> {:error, :invalid_configuration}
  end

  def load(_), do: {:error, :invalid_configuration}

  @spec https_origin?(term()) :: boolean()
  defp https_origin?(value) when is_binary(value) do
    match?(
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when is_binary(host) and host != "" and path in [nil, ""],
      URI.parse(value)
    )
  end

  defp https_origin?(_), do: false

  @spec private_path?(term()) :: boolean()
  defp private_path?(value) when is_binary(value),
    do:
      Path.type(value) == :absolute and Path.expand(value) == value and
        not String.starts_with?(value, "/nix/store/")

  defp private_path?(_), do: false
end
