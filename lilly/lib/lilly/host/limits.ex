defmodule Lilly.Host.Limits do
  @moduledoc "Effective limits of the cgroup v2 subtree that will contain the VMs, including every ancestor."
  alias Lilly.Host.Inventory

  @type t :: %{
          effective_cores: non_neg_integer(),
          effective_memory_bytes: non_neg_integer(),
          cpuset_cores: non_neg_integer(),
          cpu_quota_cores: float() | nil,
          memory_limit_bytes: non_neg_integer() | nil,
          cgroup_path: String.t()
        }

  # @cc [owner:ghuntley,label:capacity] ancestor-limits-cap-capacity
  # read/3 MUST constrain advertised CPU and memory by every enabled controller from the cgroup-v2
  # root to the VM subtree; unreadable enabled limits or an escaped/threaded path must fail.
  # Fractional CPU quotas round down with integer arithmetic, including a valid zero-core result.
  @spec read(Path.t(), Path.t(), Inventory.t()) :: {:ok, t()} | {:error, :invalid_cgroup_limits}
  def read(root, path, inventory) do
    root = Path.expand(root)
    path = Path.expand(path)

    with true <- path == root or String.starts_with?(path, root <> "/"),
         {:ok, controllers} <- File.read(Path.join(root, "cgroup.controllers")),
         true <- Enum.all?(~w(cpu memory cpuset), &(&1 in String.split(controllers))),
         {:ok, root_set} <- File.read(Path.join(root, "cpuset.cpus.effective")),
         {:ok, count} <- cpuset_count(root_set),
         {:ok, limits} <- hierarchy(root, path, %{quota: nil, memory: nil, cpuset: count}) do
      cores = min(inventory.logical_cores, limits.cpuset)

      cores =
        if limits.quota, do: min(cores, div(limits.quota.quota, limits.quota.period)), else: cores

      memory =
        if limits.memory,
          do: min(inventory.memory.total_bytes, limits.memory),
          else: inventory.memory.total_bytes

      {:ok,
       %{
         effective_cores: cores,
         effective_memory_bytes: memory,
         cpuset_cores: limits.cpuset,
         cpu_quota_cores: if(limits.quota, do: limits.quota.quota / limits.quota.period),
         memory_limit_bytes: limits.memory,
         cgroup_path: path
       }}
    else
      _ -> {:error, :invalid_cgroup_limits}
    end
  end

  @spec cpuset_count(String.t()) :: {:ok, non_neg_integer()} | :error
  def cpuset_count(text) when is_binary(text) do
    text = String.trim(text)

    if text == "" do
      {:ok, 0}
    else
      text
      |> String.split(",")
      |> Enum.reduce_while({:ok, 0, -1}, fn item, {:ok, count, previous} ->
        case range(item) do
          {:ok, first, last} when first > previous and last <= 1_048_575 ->
            {:cont, {:ok, count + last - first + 1, last}}

          _ ->
            {:halt, :error}
        end
      end)
      |> case do
        {:ok, count, _} -> {:ok, count}
        _ -> :error
      end
    end
  end

  @spec cpu_quota(String.t()) ::
          {:ok, %{quota: non_neg_integer(), period: pos_integer()} | nil} | :error
  def cpu_quota(text) do
    case String.split(text) do
      ["max", period] ->
        with {:ok, n} when n > 0 <- number(period), do: {:ok, nil}, else: (_ -> :error)

      [quota, period] ->
        with {:ok, q} <- number(quota),
             {:ok, p} when p > 0 <- number(period),
             do: {:ok, %{quota: q, period: p}},
             else: (_ -> :error)

      _ ->
        :error
    end
  end

  defp hierarchy(root, root, limits), do: {:ok, limits}

  defp hierarchy(root, path, limits) do
    parent = Path.dirname(path)

    with {:ok, limits} <- hierarchy(root, parent, limits),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, "domain" <> rest} when rest in ["", "\n"] <-
           File.read(Path.join(path, "cgroup.type")),
         {:ok, enabled} <- File.read(Path.join(parent, "cgroup.subtree_control")),
         enabled = String.split(enabled),
         {:ok, quota} <- controller(path, "cpu.max", "cpu" in enabled, &cpu_quota/1),
         {:ok, memory} <- controller(path, "memory.max", "memory" in enabled, &memory_limit/1),
         {:ok, cpuset} <-
           controller(path, "cpuset.cpus.effective", "cpuset" in enabled, &cpuset_count/1) do
      {:ok,
       %{
         quota: lower_quota(limits.quota, quota),
         memory: lower(limits.memory, memory),
         cpuset: lower(limits.cpuset, cpuset)
       }}
    else
      _ -> :error
    end
  end

  defp controller(_, _, false, _parser), do: {:ok, nil}

  defp controller(path, file, true, parser) do
    with {:ok, contents} <- File.read(Path.join(path, file)), do: parser.(contents)
  end

  defp memory_limit(text) do
    case String.trim(text) do
      "max" -> {:ok, nil}
      value -> number(value)
    end
  end

  defp lower(nil, b), do: b
  defp lower(a, nil), do: a
  defp lower(a, b), do: min(a, b)
  defp lower_quota(nil, b), do: b
  defp lower_quota(a, nil), do: a
  defp lower_quota(a, b), do: if(a.quota * b.period <= b.quota * a.period, do: a, else: b)

  defp range(text) do
    case String.split(text, "-") do
      [n] ->
        with {:ok, value} <- number(n), do: {:ok, value, value}

      [a, b] ->
        with {:ok, first} <- number(a),
             {:ok, last} when last >= first <- number(b),
             do: {:ok, first, last},
             else: (_ -> :error)

      _ ->
        :error
    end
  end

  defp number(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 and n <= 9_223_372_036_854_775_807 -> {:ok, n}
      _ -> :error
    end
  end
end
