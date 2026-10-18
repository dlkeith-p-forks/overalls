defmodule Marshall.Compute.HostLivenessTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Compute.HostLiveness

  @now ~U[2026-10-02 12:00:00.000Z]

  defp at(age_ms), do: DateTime.add(@now, -age_ms, :millisecond)

  test "the capacity window never exceeds the authority window" do
    assert HostLiveness.capacity_ms() <= HostLiveness.authority_ms()
  end

  # @cc [owner:ghuntley,label:verification;security] host-liveness-model
  # The classification MUST equal an independent model for every session and
  # report age; capacity freshness MUST imply authority; and authority MUST
  # never return as a report ages.
  property "classification matches the model and degrades monotonically with age" do
    capacity = HostLiveness.capacity_ms()
    authority = HostLiveness.authority_ms()

    session = draw("session", one_of([constant(nil), constant("session")]))
    ages = draw("ages", list_of(integer(-5000..(authority * 2)), min_length: 1, max_length: 20))

    for age <- ages do
      expected =
        cond do
          is_nil(session) -> :disconnected
          age < 0 -> :lost
          age <= capacity -> :live
          age <= authority -> :late
          true -> :lost
        end

      state = HostLiveness.state(session, at(age), @now)
      assert state == expected

      if session && HostLiveness.capacity_fresh?(at(age), @now),
        do: assert(HostLiveness.authority?(session, at(age), @now))
    end

    authorized =
      ages
      |> Enum.filter(&(&1 >= 0))
      |> Enum.sort()
      |> Enum.map(&HostLiveness.authority?(session, at(&1), @now))

    # Once authority is lost with increasing age it never comes back.
    assert authorized == Enum.sort(authorized, :desc)
  end

  test "a missing report or session never grants anything" do
    refute HostLiveness.authority?("session", nil, @now)
    refute HostLiveness.capacity_fresh?(nil, @now)
    refute HostLiveness.authority?(nil, at(0), @now)
  end
end
