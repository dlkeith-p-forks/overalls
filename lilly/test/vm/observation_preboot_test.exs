defmodule Lilly.VM.ObservationPrebootTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.VM.Observation

  # @cc [owner:ghuntley,label:verification;isolation] preboot-proof-never-proves-running
  # Generated process evidence MUST distinguish preboot from configured seccomp
  # and refuse each missing or contradictory confinement field in either phase.
  # Parser properties do not establish native confinement or snapshot execution.
  property "preboot and configured process evidence have disjoint seccomp authority" do
    pid = Hegel.draw("host PID", integer(1..2_000_000_000)) |> Integer.to_string()
    uid = Hegel.draw("jail UID", integer(100_000..200_000))

    for {phase, seccomp} <- [preboot: "0", configured: "2"] do
      fields = %{
        "Name" => "firecracker",
        "Uid" => Enum.join(List.duplicate(uid, 4), "\t"),
        "Gid" => Enum.join(List.duplicate(uid, 4), "\t"),
        "CapEff" => "0000000000000000",
        "NoNewPrivs" => "1",
        "Seccomp" => seccomp,
        "NSpid" => pid <> "\t1"
      }

      assert Observation.process_status?(status(fields), pid, uid, phase)
      other_phase = if phase == :preboot, do: :configured, else: :preboot
      refute Observation.process_status?(status(fields), pid, uid, other_phase)

      for key <- Map.keys(fields) do
        refute Observation.process_status?(status(Map.delete(fields, key)), pid, uid, phase)

        refute Observation.process_status?(
                 status(Map.put(fields, key, "invalid")),
                 pid,
                 uid,
                 phase
               )
      end

      for malformed <- ["", "malformed", <<255>>, String.duplicate("x", 65_537)] do
        refute Observation.process_status?(malformed, pid, uid, phase)
      end
    end
  end

  @spec status(%{String.t() => String.t()}) :: String.t()
  defp status(fields),
    do: Enum.map_join(fields, "\n", fn {key, value} -> key <> ":\t" <> value end)
end
