defmodule Lilly.Host.ZFSIO do
  @moduledoc "Bounded native logical pool I/O, separate from dataset capacity and physical device I/O."
  alias Lilly.Host.{Command, Pool}

  @max 9_223_372_036_854_775_807
  @guid_max 18_446_744_073_709_551_615
  @rates ~w(read_iops write_iops read_bytes_per_second write_bytes_per_second)
  @type identities :: %{String.t() => %{String.t() => String.t()}}

  # @cc [owner:ghuntley,label:capacity] zfs-io-import-bound-interval
  # sample/1 MUST use a native interval, suppress boot averages and bind every
  # result to the configured pool GUID and unchanged import GUID. Missing,
  # malformed, timed-out or rebound observations MUST remain unavailable.
  # All pools share one bounded interval; its rates MUST NOT become dataset
  # capacity, physical device rates or an inferred IOPS ceiling.
  @spec sample([Pool.t()]) :: {:ok, %{String.t() => map()}} | {:error, :zfs_io_unavailable}
  def sample([]), do: {:ok, %{}}

  def sample(pools) do
    expected = Map.new(pools, &{pool_name(&1), &1.storage.zpool_guid})
    names = Map.keys(expected) |> Enum.sort()
    started = System.monotonic_time(:millisecond)

    with true <- map_size(expected) == length(pools) and valid_names?(names),
         {:ok, before} <- identities(names),
         true <- Enum.all?(expected, fn {name, guid} -> before[name]["guid"] == guid end),
         {:ok, output} <- Command.run(:zpool_iostat, ["-Hpy"] ++ names ++ ["1", "1"]),
         {:ok, rates} <- parse_rates(output, names),
         {:ok, after_sample} <- identities(names),
         true <- before == after_sample do
      elapsed = System.monotonic_time(:millisecond) - started

      {:ok,
       Map.new(pools, fn pool ->
         name = pool_name(pool)

         io =
           unavailable(pool)
           |> Map.merge(rates[name])
           |> Map.merge(%{
             "status" => "measured",
             "zpool_load_guid" => before[name]["load_guid"],
             "collection_elapsed_ms" => elapsed
           })

         {pool.id, io}
       end)}
    else
      _ -> {:error, :zfs_io_unavailable}
    end
  end

  @spec unavailable(Pool.t()) :: map()
  def unavailable(pool) do
    %{
      "status" => "unavailable",
      "sample_interval_ms" => nil,
      "read_iops" => nil,
      "write_iops" => nil,
      "read_bytes_per_second" => nil,
      "write_bytes_per_second" => nil,
      "read_latency_ms" => nil,
      "write_latency_ms" => nil,
      "average_queue_depth" => nil,
      "in_flight" => nil,
      "busy_percent" => nil
    }
    |> Map.merge(%{
      "source" => "openzfs_zpool_iostat",
      "scope" => "zpool",
      "kind" => "logical",
      "zpool_name" => pool_name(pool),
      "zpool_load_guid" => nil,
      "rate_clock" => "openzfs_vdev_timestamp",
      # The CLI exposes rates, not the exact timestamp delta used to derive them.
      "requested_interval_ms" => 1000,
      "collection_elapsed_ms" => nil
    })
  end

  # @cc [owner:ghuntley,label:capacity] zfs-io-exact-bounded-rows
  # Parsers MUST require one complete native record per expected pool/property,
  # reject extra/duplicate/noncanonical/overflowing fields and preserve unsigned
  # GUIDs as strings. Allocated/free columns MUST NOT escape as capacity metrics.
  @spec parse_rates(binary(), [String.t()]) :: {:ok, %{String.t() => map()}} | :error
  def parse_rates(output, names) do
    with {:ok, rows} <- rows(output, names, length(names)) do
      Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
        with [name, allocated, free | rates] when length(rates) == 4 <- row,
             true <- name in names and not Map.has_key?(acc, name),
             true <- Enum.all?([allocated, free | rates], &uint?(&1, @max)) do
          values = Map.new(Enum.zip(@rates, Enum.map(rates, &String.to_integer/1)))
          {:cont, {:ok, Map.put(acc, name, values)}}
        else
          _ -> {:halt, :error}
        end
      end)
    end
  end

  @spec parse_identities(binary(), [String.t()]) :: {:ok, identities()} | :error
  def parse_identities(output, names) do
    with {:ok, rows} <- rows(output, names, 2 * length(names)) do
      Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
        with [name, property, value] <- row,
             true <- name in names and property in ["guid", "load_guid"],
             true <- uint?(value, @guid_max) and value != "0",
             properties = Map.get(acc, name, %{}),
             false <- Map.has_key?(properties, property) do
          {:cont, {:ok, Map.put(acc, name, Map.put(properties, property, value))}}
        else
          _ -> {:halt, :error}
        end
      end)
    end
  end

  defp identities(names) do
    with {:ok, output} <-
           Command.run(
             :zpool_get,
             ["-Hp", "-o", "name,property,value", "guid,load_guid"] ++ names
           ) do
      parse_identities(output, names)
    end
  end

  defp rows(output, names, count) when is_binary(output) and byte_size(output) <= 65_536 do
    with true <- valid_names?(names) and String.valid?(output) and String.ends_with?(output, "\n"),
         rows = output |> String.trim_trailing("\n") |> String.split("\n"),
         true <- length(rows) == count and not String.ends_with?(output, "\n\n") do
      {:ok, Enum.map(rows, &String.split(&1, "\t"))}
    else
      _ -> :error
    end
  end

  defp rows(_, _, _), do: :error

  defp valid_names?(names) do
    length(names) in 1..64 and length(Enum.uniq(names)) == length(names) and
      Enum.all?(names, fn name ->
        is_binary(name) and byte_size(name) in 1..255 and String.valid?(name) and
          Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_.:-]*\z/, name)
      end)
  end

  defp uint?(value, max) do
    byte_size(value) in 1..20 and Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value) and
      String.to_integer(value) <= max
  end

  defp pool_name(pool), do: pool.storage.dataset |> String.split("/", parts: 2) |> hd()
end
