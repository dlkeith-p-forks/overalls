defmodule Lilly.VM.ObservationIncarnationTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.VM.Observation

  # @cc [owner:ghuntley,label:verification;isolation] live-restore-rejects-pid-reuse
  # The kernel PID/start-time token MUST distinguish replacement processes even
  # when the numeric PID is reused. Invalid or mismatched proc framing MUST
  # refuse. Parser checks do not establish confinement of a native process.
  property "restored process incarnation cannot survive PID reuse or malformed proc evidence" do
    pid = Hegel.draw("native PID", integer(1..2_000_000_000))
    started = Hegel.draw("kernel start ticks", integer(1..9_223_372_036_854_775_000))
    stat = stat(pid, Integer.to_string(started))
    expected = {pid, started}
    assert {:ok, ^expected} = Observation.parse_incarnation(pid, stat)

    assert {:ok, different} =
             Observation.parse_incarnation(pid, stat(pid, Integer.to_string(started + 1)))

    refute different == expected

    for invalid <- [
          "",
          stat(pid, "-1"),
          stat(pid, "0"),
          stat(pid, "01"),
          stat(pid, "1.0"),
          stat(pid + 1, Integer.to_string(started)),
          String.replace(stat, "(firecracker)", "(jailer)"),
          stat <> <<255>>,
          String.duplicate("x", 4097)
        ],
        do:
          assert(
            {:error, :physical_identity_unconfirmed} = Observation.parse_incarnation(pid, invalid)
          )
  end

  @spec stat(pos_integer(), String.t()) :: String.t()
  defp stat(pid, started),
    do:
      "#{pid} (firecracker) " <>
        Enum.join(["S" | List.duplicate("0", 18)] ++ [started, "0"], " ") <> "\n"
end
