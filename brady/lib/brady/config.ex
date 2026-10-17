defmodule Brady.Config do
  @moduledoc "Closed runtime configuration; operator policy cannot disable origin isolation."
  @keys ~w(version host_id attribution_uid issuer_cert_file issuer_key_file upstream_ca_file protected_cidrs tls_exceptions cache_directory cache_dataset cache_quota_bytes)
  @uuid ~r/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
  @gib 1_073_741_824

  @spec load(Path.t()) :: {:ok, map()} | {:error, :invalid_configuration}
  def load(path) do
    with {:ok, %{type: :regular, size: size}} <- File.stat(path),
         true <- size <= 65_536,
         {:ok, bytes} <- File.open(path, [:read, :binary], &IO.binread(&1, 65_537)),
         true <- is_binary(bytes) and byte_size(bytes) <= 65_536,
         {:ok, value} <- JSON.decode(bytes),
         do: validate(value),
         else: (_ -> {:error, :invalid_configuration})
  rescue
    _ -> {:error, :invalid_configuration}
  end

  # @cc [owner:ghuntley,label:security] brady-runtime-policy-closed
  # Configuration MUST reject unknown fields, malformed exceptions and unbounded
  # limits. It MUST retain built-in protected networks and the fixed upstream
  # socket mark; configuration MUST NOT admit custom socket options or functions.
  @spec validate(term()) :: {:ok, map()} | {:error, :invalid_configuration}
  def validate(value) when is_map(value) do
    with true <- Enum.sort(Map.keys(value)) == Enum.sort(@keys),
         1 <- value["version"],
         host when is_binary(host) <- value["host_id"],
         true <- Regex.match?(@uuid, host),
         uid when is_integer(uid) and uid in 0..4_294_967_294 <- value["attribution_uid"],
         true <-
           Enum.all?(
             ~w(issuer_cert_file issuer_key_file upstream_ca_file cache_directory),
             &path?(value[&1])
           ),
         dataset when is_binary(dataset) <- value["cache_dataset"],
         true <-
           byte_size(dataset) <= 256 and
             Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9_.-]*\/[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/, dataset),
         false <- String.starts_with?(value["issuer_key_file"], "/nix/store/"),
         quota when is_integer(quota) and quota >= 1_048_576 and quota <= 256 * @gib <-
           value["cache_quota_bytes"],
         {:ok, policy} <- Brady.Destination.policy(value["protected_cidrs"]),
         {:ok, exceptions} <- exceptions(value["tls_exceptions"]) do
      {:ok,
       %{
         host_id: host,
         attribution_uid: uid,
         certfile: value["issuer_cert_file"],
         keyfile: value["issuer_key_file"],
         upstream_ca_file: value["upstream_ca_file"],
         destination_policy: policy,
         tls_exceptions: exceptions,
         cache_directory: value["cache_directory"],
         cache_dataset: dataset,
         limits: %{
           quota: quota,
           object: min(16 * @gib, div(quota, 10)),
           high: div(quota * 90, 100),
           low: div(quota * 80, 100)
         }
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def validate(_), do: {:error, :invalid_configuration}

  @spec proxy(map()) :: map()
  def proxy(config) do
    Map.take(config, [:destination_policy, :upstream_ca_file, :tls_exceptions])
    |> Map.merge(%{
      cache: Brady.Cache.Store,
      signer: Brady.TLS.Certificates,
      socket_options: [{:raw, 1, 36, <<0x42524145::native-unsigned-32>>}],
      resolver: &resolve/1,
      attribution: &Brady.Attribution.lookup(config.host_id, config.attribution_uid, &1)
    })
  end

  @spec resolve(String.t()) :: {:ok, [Brady.Destination.ipv4()]} | {:error, :dns}
  def resolve(host) do
    case :inet.gethostbyname(String.to_charlist(host), :inet, 2_000) do
      {:ok, {:hostent, _, _, :inet, 4, addresses}} when length(addresses) in 1..64 ->
        {:ok, addresses}

      _ ->
        {:error, :dns}
    end
  end

  defp path?(value),
    do:
      is_binary(value) and byte_size(value) in 2..4096 and
        String.valid?(value) and not Regex.match?(~r/[\x00-\x1f\x7f]/, value) and
        Path.type(value) == :absolute and Path.expand(value) == value

  defp exceptions(rows) when is_list(rows) and length(rows) <= 256 do
    Enum.reduce_while(rows, {:ok, MapSet.new()}, fn row, {:ok, acc} ->
      case row do
        %{"host" => host, "port" => port}
        when map_size(row) == 2 and is_integer(port) and port in 1..65535 ->
          case Brady.Destination.hostname(host) do
            {:ok, ^host} -> {:cont, {:ok, MapSet.put(acc, {host, port})}}
            _ -> {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp exceptions(_), do: :error
end
