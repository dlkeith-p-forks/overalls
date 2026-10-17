defmodule OverallsAntithesis.Lilly.Ownership do
  @moduledoc "Container-local exclusive owner for the explicitly controlled hosted boundary."
  alias Lilly.Control.Config
  alias Lilly.Host.{Identity, Lock}

  # @cc [owner:ghuntley,label:security;recovery] hosted-owner-is-exclusive
  # The fixed host lock and machine identity still fence duplicate Lilly runtimes.
  # This owner does not attest systemd, KVM, ZFS or native VM units.
  @spec acquire(Config.t()) :: {:ok, port()} | {:error, atom()}
  def acquire(%{client: client, cgroup_path: "/sys/fs/cgroup/lilly.slice", pools: pools}) do
    with {:ok, %File.Stat{uid: 0}} <- File.stat("/proc/self"),
         {:ok, machine} <- Identity.read(),
         true <- machine == client.machine_id,
         true <- Enum.all?(pools, &(&1.backend == :controlled)),
         {:ok, lock} <- Lock.acquire("/run/lilly") do
      {:ok, lock}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :host_execution_unavailable}
    end
  end

  def acquire(_), do: {:error, :host_execution_unavailable}

  # Controlled execution has no native VM units. Guest builds require their own
  # process inventory before restored actors may be resumed.
  @spec verify_units([OverallsProtocol.Execution.command()]) ::
          :ok | {:error, :untracked_vm_units}
  if System.get_env("ANTITHESIS_GUEST") == "1" do
    def verify_units(commands), do: OverallsAntithesis.Lilly.GuestExecutor.verify_units(commands)
  else
    def verify_units(commands) when is_list(commands) do
      ids = Enum.map(commands, & &1.placement_id)
      if length(ids) == length(Enum.uniq(ids)), do: :ok, else: {:error, :untracked_vm_units}
    end
  end
end
