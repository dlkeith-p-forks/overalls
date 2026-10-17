defmodule Ziggy.SLOCheckpoint do
  @moduledoc "Private fsynced aggregate and bounded completion replay identities."
  import Bitwise
  alias Ziggy.SLO
  alias Overalls.RequestAccounting.Aggregate

  @name ".slo-checkpoint"
  @maximum 9_223_372_036_854_775_807
  @counters ~w(requests successes failures duration_count duration_sum_us)
  @keys Enum.sort(@counters ++ ~w(started_at_unix_nano incarnation bucket_counts))
  @type seen :: MapSet.t(String.t())
  @type result :: {:ok, SLO.t(), seen()} | {:error, :invalid_checkpoint}

  @spec names() :: [String.t()]
  def names, do: [@name, @name <> ".pending"]

  # @cc [owner:ghuntley,label:security;durability] ziggy-checkpoint-private-validation
  # Only the owned private regular bounded checkpoint may restore totals.
  # Reject unknown fields, invalid arithmetic and duplicate or non-UUID replay
  # identities. Missing checkpoints establish a new source lifetime, never old
  # continuity. Interrupted staging never replaces the committed checkpoint.
  @spec load(String.t(), pos_integer()) :: result()
  def load(directory, maximum) do
    result =
      case File.lstat(Path.join(directory, @name)) do
        {:error, :enoent} -> {:ok, SLO.new(), MapSet.new()}
        {:ok, stat} -> read(directory, stat, maximum)
        _ -> {:error, :invalid_checkpoint}
      end

    with {:ok, slo, seen} <- result,
         :ok <- remove_stage(directory) do
      {:ok, slo, seen}
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  @spec read(String.t(), File.Stat.t(), pos_integer()) :: result()
  defp read(directory, stat, maximum) do
    with true <- private?(stat),
         true <- stat.size <= 4096 + maximum * 40,
         {:ok, bytes} <- File.read(Path.join(directory, @name)),
         {:ok, wire} <- Jason.decode(bytes) do
      decode(wire, maximum)
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  @spec decode(term(), pos_integer()) :: result()
  def decode(%{"version" => 1, "slo" => slo, "seen" => seen} = wire, maximum)
      when is_map(slo) and is_list(seen) do
    with true <- Enum.sort(Map.keys(wire)) == ~w(seen slo version),
         true <- Enum.sort(Map.keys(slo)) == @keys,
         true <- length(seen) <= maximum,
         true <- Enum.all?(seen, &OverallsProtocol.uuid?/1),
         true <- length(Enum.uniq(seen)) == length(seen),
         true <- Enum.all?(@counters, &counter?(slo[&1])),
         true <- is_integer(slo["started_at_unix_nano"]) and slo["started_at_unix_nano"] > 0,
         true <-
           slo["started_at_unix_nano"] <= System.system_time(:nanosecond) + 2_000_000_000,
         true <-
           is_binary(slo["incarnation"]) and
             Regex.match?(~r/\A[0-9a-f]{32}\z/, slo["incarnation"]),
         buckets when is_list(buckets) <- slo["bucket_counts"],
         true <- length(buckets) == 8 and Enum.all?(buckets, &counter?/1),
         true <- slo["requests"] == slo["successes"] + slo["failures"],
         true <- slo["duration_count"] <= slo["requests"],
         true <- Enum.sum(buckets) == slo["duration_count"] do
      {:ok,
       %Aggregate{
         service: "ziggy",
         started_at_unix_nano: slo["started_at_unix_nano"],
         incarnation: slo["incarnation"],
         invocation_id: slo["incarnation"],
         requests: slo["requests"],
         successes: slo["successes"],
         failures: slo["failures"],
         duration_count: slo["duration_count"],
         duration_sum_us: slo["duration_sum_us"],
         bucket_counts: List.to_tuple(buckets)
       }, MapSet.new(seen)}
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  def decode(_, _), do: {:error, :invalid_checkpoint}

  @spec counter?(term()) :: boolean()
  defp counter?(value), do: is_integer(value) and value in 0..@maximum

  @spec wire(SLO.t(), seen()) :: map()
  def wire(slo, seen) do
    %{
      "version" => 1,
      "slo" => %{
        "bucket_counts" => Tuple.to_list(slo.bucket_counts),
        "duration_count" => slo.duration_count,
        "duration_sum_us" => slo.duration_sum_us,
        "failures" => slo.failures,
        "incarnation" => slo.incarnation,
        "requests" => slo.requests,
        "started_at_unix_nano" => slo.started_at_unix_nano,
        "successes" => slo.successes
      },
      "seen" => seen |> MapSet.to_list() |> Enum.sort()
    }
  end

  # @cc [owner:ghuntley,label:durability;recovery] ziggy-checkpoint-before-ack
  # Aggregate replacement MUST fsync its private stage, atomically rename it
  # and fsync the directory before an acknowledged completion can be removed.
  # Replay identities may be forgotten only after durable spool removal.
  @spec save(String.t(), SLO.t(), seen(), pos_integer()) :: :ok | {:error, :invalid_checkpoint}
  def save(directory, slo, seen, maximum) do
    wire = wire(slo, seen)
    stage = Path.join(directory, @name <> ".pending")

    with {:ok, _, _} <- decode(wire, maximum),
         :ok <- write_stage(stage, Jason.encode!(wire)),
         :ok <- File.rename(stage, Path.join(directory, @name)),
         :ok <- sync_directory(directory) do
      :ok
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  @spec write_stage(String.t(), binary()) :: :ok | {:error, term()}
  defp write_stage(path, bytes) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:raw, :binary, :write, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             :ok <- :file.write(file, bytes),
             do: :file.sync(file)
      after
        :file.close(file)
      end
    end
  end

  @spec private?(File.Stat.t()) :: boolean()
  defp private?(%File.Stat{type: :regular, links: 1, uid: uid, mode: mode}) do
    match?({:ok, %File.Stat{uid: ^uid}}, File.stat("/proc/self")) and band(mode, 0o077) == 0
  end

  defp private?(_), do: false

  @spec remove_stage(String.t()) :: :ok | {:error, term()}
  defp remove_stage(directory) do
    path = Path.join(directory, @name <> ".pending")

    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, stat} ->
        with true <- private?(stat),
             :ok <- File.rm(path),
             :ok <- sync_directory(directory) do
          :ok
        else
          _ -> {:error, :invalid_checkpoint}
        end

      error ->
        error
    end
  end

  @spec sync_directory(String.t()) :: :ok | {:error, term()}
  defp sync_directory(path) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      try do
        :file.sync(file)
      after
        :file.close(file)
      end
    end
  end
end
