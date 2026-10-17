defmodule Lilly.Host.Usage do
  @moduledoc "Physical headroom across the guest cgroup, ancestors and the whole host."
  alias Lilly.Host.{Inventory, Limits}
  @type previous :: map() | nil

  # @cc [owner:ghuntley,label:capacity] usage-scoped-complete-interval
  # sample/6 MUST use every constrained ancestor and host availability. Missing,
  # reset, replaced or overlong CPU intervals MUST yield unknown headroom. Only
  # identical placement proofs at both interval boundaries may cover startup.
  @spec sample(Path.t(), Path.t(), Inventory.t(), map(), previous(), map()) ::
          {map() | nil, previous()}
  def sample(root, path, inventory, limits, previous, coverage) do
    root = Path.expand(root)
    path = Path.expand(path)

    with true <- path != root and String.starts_with?(path, root <> "/"),
         true <- map_size(coverage) <= 4096,
         {:ok, scopes} <- scopes(root, path, inventory.logical_cores),
         now = System.monotonic_time(:microsecond) do
      current = %{scopes: scopes, at: now, coverage: coverage}
      {headroom(current, previous, inventory, limits), current}
    else
      _ -> {nil, nil}
    end
  end

  defp headroom(current, %{at: before, scopes: prior, coverage: coverage}, inventory, limits) do
    elapsed = current.at - before

    with true <- elapsed in 1..5_000_000,
         true <- Map.keys(current.scopes) == Map.keys(prior),
         {:ok, cpu} <- cpu_headroom(current.scopes, prior, elapsed),
         available when is_integer(available) <- inventory.memory.available_bytes do
      memory =
        Enum.reduce(current.scopes, min(available, limits.effective_memory_bytes), fn
          {_, %{memory: {maximum, used}}}, free -> min(free, max(0, maximum - used))
          _, free -> free
        end)

      %{
        "version" => 1,
        "cpu_headroom_millicores" => min(cpu, limits.effective_cores * 1000),
        "memory_headroom_bytes" => max(0, memory),
        "interval_us" => elapsed,
        "covered" => Map.filter(current.coverage, fn {id, proof} -> coverage[id] == proof end)
      }
    else
      _ -> nil
    end
  end

  defp headroom(_, _, _, _), do: nil

  defp cpu_headroom(scopes, prior, elapsed) do
    Enum.reduce_while(scopes, {:ok, 9_223_372_036_854_775_807}, fn {path, scope}, {:ok, free} ->
      old = prior[path]

      if old.identity == scope.identity and scope.usage >= old.usage do
        used = div((scope.usage - old.usage) * 1000 + elapsed - 1, elapsed)
        {:cont, {:ok, min(free, max(0, scope.cpu - used))}}
      else
        {:halt, :error}
      end
    end)
  end

  defp scopes(root, root, cores) do
    with {:ok, scope} <- scope(root, cores, []) do
      {:ok, %{root => scope}}
    end
  end

  defp scopes(root, path, cores) do
    parent = Path.dirname(path)

    with {:ok, scopes} <- scopes(root, parent, cores),
         {:ok, controllers} <- File.read(Path.join(parent, "cgroup.subtree_control")),
         {:ok, scope} <- scope(path, cores, String.split(controllers)) do
      {:ok, Map.put(scopes, path, scope)}
    end
  end

  defp scope(path, cores, controllers) do
    with {:ok, stat} <- File.stat(path),
         {:ok, counters} <- File.read(Path.join(path, "cpu.stat")),
         [_, text] <- Regex.run(~r/^usage_usec ([0-9]+)$/m, counters),
         {:ok, usage} <- number(text),
         {:ok, cpu} <- cpu_limit(path, cores, controllers),
         {:ok, memory} <- memory_limit(path, controllers) do
      {:ok, %{identity: {stat.major_device, stat.inode}, usage: usage, cpu: cpu, memory: memory}}
    else
      _ -> :error
    end
  end

  defp cpu_limit(path, cores, controllers) do
    with {:ok, cpus} <- cpus(path, cores, controllers),
         {:ok, quota} <- quota(path, controllers) do
      {:ok,
       if(quota, do: min(cpus * 1000, div(quota.quota * 1000, quota.period)), else: cpus * 1000)}
    end
  end

  defp cpus(path, cores, controllers) do
    if "cpuset" in controllers do
      with {:ok, text} <- File.read(Path.join(path, "cpuset.cpus.effective")),
           {:ok, count} <- Limits.cpuset_count(text),
           do: {:ok, min(cores, count)}
    else
      {:ok, cores}
    end
  end

  defp quota(path, controllers) do
    if "cpu" in controllers do
      with {:ok, text} <- File.read(Path.join(path, "cpu.max")), do: Limits.cpu_quota(text)
    else
      {:ok, nil}
    end
  end

  defp memory_limit(path, controllers) do
    if "memory" in controllers do
      with {:ok, maximum} <- File.read(Path.join(path, "memory.max")),
           {:ok, used} <- File.read(Path.join(path, "memory.current")),
           {:ok, used} <- number(String.trim(used)) do
        case String.trim(maximum) do
          "max" -> {:ok, nil}
          maximum -> with {:ok, maximum} <- number(maximum), do: {:ok, {maximum, used}}
        end
      end
    else
      {:ok, nil}
    end
  end

  defp number(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 and n <= 9_223_372_036_854_775_807 -> {:ok, n}
      _ -> :error
    end
  end
end
