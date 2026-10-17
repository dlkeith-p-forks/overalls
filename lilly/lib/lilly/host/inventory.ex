defmodule Lilly.Host.Inventory do
  @moduledoc """
  CPU topology and memory observations reported by Linux procfs.

  This is physical inventory, not a scheduling reservation or a cgroup limit.
  Missing topology remains unknown. Malformed/missing capacity fails explicitly
  so consumers cannot mistake collection failure for unused capacity.
  """

  @enforce_keys [:architecture, :logical_cores, :memory]
  defstruct [:architecture, :cpu_model, :logical_cores, :physical_cores, :sockets, :memory]

  @type memory :: %{
          total_bytes: pos_integer(),
          free_bytes: non_neg_integer(),
          available_bytes: non_neg_integer(),
          used_bytes: non_neg_integer(),
          utilization_percent: float()
        }
  @type cpu :: %{
          cpu_model: String.t() | nil,
          logical_cores: pos_integer(),
          physical_cores: pos_integer() | nil,
          sockets: pos_integer() | nil
        }
  @type t :: %__MODULE__{
          architecture: String.t(),
          cpu_model: String.t() | nil,
          logical_cores: pos_integer(),
          physical_cores: pos_integer() | nil,
          sockets: pos_integer() | nil,
          memory: memory()
        }

  @doc "Reads procfs. An alternate procfs directory supports deterministic tests."
  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(proc_root \\ "/proc") do
    with {:ok, cpuinfo} <- File.read(Path.join(proc_root, "cpuinfo")),
         {:ok, meminfo} <- File.read(Path.join(proc_root, "meminfo")),
         {:ok, cpu} <- parse_cpu(cpuinfo),
         {:ok, memory} <- parse_memory(meminfo) do
      architecture =
        :erlang.system_info(:system_architecture)
        |> List.to_string()
        |> String.split("-", parts: 2)
        |> hd()

      {:ok, struct!(__MODULE__, Map.merge(cpu, %{architecture: architecture, memory: memory}))}
    end
  end

  @doc "Parses Linux CPU records, preserving unknown physical topology as nil."
  # @cc [owner:ghuntley,label:capacity] physical-topology-remains-unknown
  # parse_cpu/1 MUST count distinct processor records for logical cores and return nil physical
  # cores/sockets if any required topology field is missing; it must not infer physical topology
  # from the logical count.
  @spec parse_cpu(String.t()) :: {:ok, cpu()} | {:error, :invalid_cpu_inventory}
  def parse_cpu(text) do
    records = text |> String.split(~r/\n\s*\n/, trim: true) |> Enum.map(&fields/1)
    processors = Enum.map(records, & &1["processor"])

    if records != [] and Enum.all?(processors, &integer_string?/1) and
         length(Enum.uniq(processors)) == length(processors) do
      topology? =
        Enum.all?(records, fn record ->
          integer_string?(record["physical id"]) and integer_string?(record["core id"])
        end)

      {:ok,
       %{
         cpu_model: records |> hd() |> Map.get("model name"),
         logical_cores: length(records),
         physical_cores:
           if(topology?,
             do:
               records |> Enum.map(&{&1["physical id"], &1["core id"]}) |> Enum.uniq() |> length()
           ),
         sockets:
           if(topology?, do: records |> Enum.map(& &1["physical id"]) |> Enum.uniq() |> length())
       }}
    else
      {:error, :invalid_cpu_inventory}
    end
  end

  @doc "Parses byte capacities; used means total minus reclaimable available memory."
  # @cc [owner:ghuntley,label:capacity] memory-observations-conserve-bytes
  # parse_memory/1 MUST require MemTotal, MemFree and MemAvailable in Linux kB units, convert them
  # to bytes and define used as total minus available. Missing or out-of-range observations must
  # fail rather than become free capacity.
  @spec parse_memory(String.t()) :: {:ok, memory()} | {:error, :invalid_memory_inventory}
  def parse_memory(text) do
    values = fields(text)

    with {:ok, total} when total > 0 <- kibibytes(values["MemTotal"]),
         {:ok, free} when free <= total <- kibibytes(values["MemFree"]),
         {:ok, available} when available <= total <-
           kibibytes(values["MemAvailable"]) do
      used = total - available

      {:ok,
       %{
         total_bytes: total,
         free_bytes: free,
         available_bytes: available,
         used_bytes: used,
         utilization_percent: used * 100.0 / total
       }}
    else
      _ -> {:error, :invalid_memory_inventory}
    end
  end

  defp fields(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> [{String.trim(key), String.trim(value)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp integer_string?(value) when is_binary(value), do: Regex.match?(~r/^\d+$/, value)
  defp integer_string?(_), do: false

  defp kibibytes(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)\s+kB$/, value, capture: :all_but_first) do
      [number] -> {:ok, String.to_integer(number) * 1024}
      _ -> :error
    end
  end

  defp kibibytes(_), do: :error
end
