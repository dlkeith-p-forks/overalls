defmodule Enrico.Config do
  @moduledoc "Validated runtime settings; no secret enters a Nix build or diagnostic."
  @enforce_keys [:bind, :port, :state_dir, :token, :certificate, :key, :status_socket]
  defstruct [:bind, :port, :state_dir, :token, :certificate, :key, :status_socket]

  @type t :: %__MODULE__{
          bind: :inet.ip4_address(),
          port: pos_integer(),
          state_dir: binary(),
          token: binary(),
          certificate: binary(),
          key: binary(),
          status_socket: binary()
        }

  # @cc [owner:ghuntley,label:security] enrico-bind-type-before-conversion
  # Non-string JSON bind values MUST return invalid_configuration before
  # address conversion or state-directory creation, without raising.
  @spec load(binary()) :: {:ok, t()} | {:error, :invalid_configuration}
  def load(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, value} <- JSON.decode(bytes),
         %{
           "bind" => bind,
           "port" => port,
           "state_dir" => state,
           "token_file" => token_file,
           "certificate_file" => cert,
           "key_file" => key,
           "status_socket" => socket
         } <- value,
         true <- is_binary(bind),
         {:ok, address} <- :inet.parse_ipv4_address(String.to_charlist(bind)),
         true <- is_integer(port) and port in 1..65_535,
         true <- Enum.all?([state, token_file, cert, key, socket], &absolute?/1),
         {:ok, token} <- File.read(token_file),
         true <- byte_size(token) in 32..256 and not String.contains?(token, ["\n", "\r"]),
         true <- File.regular?(cert) and File.regular?(key),
         :ok <- File.mkdir_p(state),
         true <- File.dir?(state) do
      {:ok,
       %__MODULE__{
         bind: address,
         port: port,
         state_dir: state,
         token: token,
         certificate: cert,
         key: key,
         status_socket: socket
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def load(_), do: {:error, :invalid_configuration}

  defp absolute?(value), do: is_binary(value) and Path.type(value) == :absolute
end
