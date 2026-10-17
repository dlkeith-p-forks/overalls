defmodule Lilly.VM.Observation do
  @moduledoc "Confirm process identity, confinement and API readiness before reporting a running VMM."
  alias Lilly.Host.{Command, Pool}
  alias Lilly.VM.{API, Config, Jail, Spec, Unit}
  # @cc [owner:ghuntley,label:isolation] running-means-verified-confinement
  # running?/3 MUST return true only for the expected VMM identity, jail root, network namespace,
  # UID/GID, seccomp/no-new-privileges and resource limits with a matching running API response;
  # unavailable evidence must return false.
  @spec running?(Config.t(), Pool.t(), Spec.t()) :: boolean()
  def running?(config, pool, spec), do: match?({:ok, _}, vmm(config, pool, spec))

  @doc "The verified running VMM's host PID and unit cgroup, under the same checks as running?/3."
  @spec vmm(Config.t(), Pool.t(), Spec.t()) ::
          {:ok, %{pid: pos_integer(), cgroup: Path.t()}} | :error
  def vmm(config, pool, spec) do
    with {:ok, :running} <- Unit.status(spec),
         {:ok, procs} <- File.read(Path.join(Unit.cgroup(spec), "cgroup.procs")),
         pids = String.split(procs),
         true <- length(pids) in 1..64,
         [pid] <- Enum.filter(pids, &vmm?(&1, spec)),
         true <-
           same_files?([
             {"/proc/#{pid}/root", Jail.root(pool, spec)},
             {"/proc/#{pid}/ns/net", "/run/netns/" <> config.network.namespace},
             {"/proc/#{pid}/exe", Path.join(Jail.root(pool, spec), "firecracker")}
           ]),
         true <- limits?(spec),
         true <- API.running?(Path.join(Jail.root(pool, spec), "api.sock"), spec.id),
         {:ok, :running} <- Unit.status(spec),
         do: {:ok, %{pid: String.to_integer(pid), cgroup: Unit.cgroup(spec)}},
         else: (_ -> :error)
  end

  defp vmm?(pid, spec) do
    with true <- Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, pid),
         {:ok, body} <- File.read("/proc/#{pid}/status") do
      fields =
        body
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [k, v] = String.split(line, ":", parts: 2)
          {k, String.split(v)}
        end)

      fields["Name"] == ["firecracker"] and
        fields["Uid"] == List.duplicate(Integer.to_string(spec.network.uid), 4) and
        fields["Gid"] == List.duplicate(Integer.to_string(spec.network.uid), 4) and
        fields["CapEff"] == ["0000000000000000"] and fields["NoNewPrivs"] == ["1"] and
        fields["Seccomp"] == ["2"] and fields["NSpid"] == [pid, "1"]
    else
      _ -> false
    end
  end

  defp limits?(spec) do
    with {:ok, cpu} <- File.read(Path.join(Unit.cgroup(spec), "cpu.max")),
         [quota, period] <- String.split(cpu),
         {quota, ""} <- Integer.parse(quota),
         {period, ""} <- Integer.parse(period),
         true <- period > 0 and quota == spec.vcpu * period,
         {:ok, memory} <- File.read(Path.join(Unit.cgroup(spec), "memory.max")),
         true <- String.trim(memory) == Integer.to_string(Spec.host_memory(spec)),
         {:ok, swap} <- File.read(Path.join(Unit.cgroup(spec), "memory.swap.max")),
         true <- String.trim(swap) == "0",
         do: true,
         else: (_ -> false)
  end

  # @cc [owner:ghuntley,label:isolation;security] vmm-identity-through-hostd
  # same_files?/1 MUST compare device and inode of each pair through one
  # lilly-hostd `stat -L` read, so the VMM's /proc root, network namespace
  # and executable, which need ptrace-level access, are never read by the
  # BEAM itself (ADR-0182). Any missing, malformed or partial answer MUST be
  # false.
  defp same_files?(pairs) do
    paths = Enum.flat_map(pairs, fn {a, b} -> [a, b] end)

    with {:ok, output} <- Command.run(:stat, ["-L", "--format=%d:%i", "--" | paths]),
         identities = String.split(output, "\n", trim: true),
         true <- length(identities) == length(paths),
         true <- Enum.all?(identities, &Regex.match?(~r/\A[0-9]+:[0-9]+\z/, &1)) do
      identities
      |> Enum.chunk_every(2)
      |> Enum.all?(fn [a, b] -> a == b end)
    else
      _ -> false
    end
  end
end
