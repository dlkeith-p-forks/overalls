defmodule OverallsAntithesis.Lilly.PoolConfig do
  @moduledoc "Validated configured pool identity for the hosted control harness. No ZFS observation is inferred."
  alias Lilly.Host.Pool

  @max_bytes 9_223_372_036_854_775_807

  # @cc [owner:ghuntley,label:capacity;security] controlled-pool-has-no-native-credit
  # The harness may bind a configured identity for Control negotiation, but it
  # MUST mark the backend controlled and require live capacity evidence elsewhere.
  # Only current Pool configuration keys and the production template budget and
  # image I/O deadline bounds are accepted; retired logical budgets (ADR-0159)
  # and standby keys (ADR-0177) MUST be refused.
  @spec decode([map()], OverallsProtocol.uuid()) :: {:ok, [Pool.t()]} | :error
  def decode(values, host) when is_list(values) and length(values) <= 64 do
    with true <- OverallsProtocol.uuid?(host),
         {:ok, pools} <- decode_all(values, host),
         true <- Pool.distinct?(pools) do
      {:ok, pools}
    else
      _ -> :error
    end
  end

  def decode(_, _), do: :error

  defp decode_all(values, host) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case decode_one(value, host) do
        {:ok, pool} -> {:cont, {:ok, [pool | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, pools} -> {:ok, Enum.reverse(pools)}
      :error -> :error
    end
  end

  defp decode_one(
         %{
           "id" => id,
           "path" => path,
           "filesystem_id" => fs,
           "storage" => raw_storage
         } = value,
         host
       ) do
    with true <- Pool.configuration_keys?(value),
         true <- OverallsProtocol.uuid?(id),
         true <- path?(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, storage} <- OverallsProtocol.Storage.identity(raw_storage),
         true <- fs == OverallsProtocol.Storage.filesystem_id(storage),
         template = Map.get(value, "template_budget_bytes", 34_359_738_368),
         true <- is_integer(template) and template in 1..1_099_511_627_776,
         io_timeout = Map.get(value, "image_io_timeout_ms", 300_000),
         true <- is_integer(io_timeout) and io_timeout in 1_000..14_400_000,
         {:ok, max_iops, source} <- max_iops(value) do
      {:ok,
       %Pool{
         id: id,
         path: path,
         filesystem_id: fs,
         max_iops: max_iops,
         max_iops_source: source,
         storage: storage,
         host_id: host,
         template_budget_bytes: template,
         image_io_timeout_ms: io_timeout,
         backend: :controlled,
         extents: []
       }}
    else
      _ -> :error
    end
  end

  defp decode_one(_, _), do: :error

  defp path?(path) when is_binary(path) do
    Path.type(path) == :absolute and Path.expand(path) == path and path != "/" and
      not String.starts_with?(path <> "/", "/nix/store/") and
      not String.contains?(path, [<<0>>, "\n", "\r"])
  end

  defp path?(_), do: false

  defp max_iops(value) do
    case {Map.get(value, "max_iops"), Map.get(value, "max_iops_source")} do
      {nil, nil} ->
        {:ok, nil, nil}

      {n, source} when is_integer(n) and n in 1..@max_bytes and is_binary(source) ->
        if byte_size(source) in 1..256, do: {:ok, n, source}, else: :error

      _ ->
        :error
    end
  end
end
