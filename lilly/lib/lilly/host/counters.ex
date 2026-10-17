defmodule Lilly.Host.Counters do
  @moduledoc "Linux CPU counters. Utilization never bridges counter resets."
  @type cpu :: %{total: non_neg_integer(), idle: non_neg_integer()}
  # @cc [owner:ghuntley,label:capacity] cpu-guests-not-double-counted
  # cpu/1 MUST exclude separate guest and guest_nice fields from total CPU time because Linux
  # already includes them in user and nice counters.
  @spec cpu(String.t()) :: {:ok, cpu()} | :error
  def cpu(text) do
    with ["cpu" | fields] <- text |> String.split("\n", parts: 2) |> hd() |> String.split(),
         {:ok, [user, nice, system, idle, iowait, irq, softirq, steal | _]} <- numbers(fields) do
      # guest and guest_nice are already included in user/nice.
      {:ok,
       %{total: user + nice + system + idle + iowait + irq + softirq + steal, idle: idle + iowait}}
    else
      _ -> :error
    end
  end

  # @cc [owner:ghuntley,label:capacity] cpu-invalid-deltas-stay-unknown
  # cpu_percent/2 MUST return nil for missing, reset or incoherent counters rather than report
  # zero utilization; measured percentages require a positive total delta and a nonnegative idle
  # delta no greater than it.
  @spec cpu_percent(cpu() | nil, cpu() | nil) :: float() | nil
  def cpu_percent(%{total: before_total, idle: before_idle}, %{total: total, idle: idle})
      when total > before_total and idle >= before_idle and
             total - before_total >= idle - before_idle,
      do: (total - before_total - (idle - before_idle)) * 100.0 / (total - before_total)

  def cpu_percent(_, _), do: nil

  defp numbers(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case Integer.parse(value) do
        {number, ""} when number >= 0 -> {:cont, {:ok, [number | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end
end
