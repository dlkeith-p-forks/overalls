defmodule Audi.HegelFixturesTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Overalls.HegelFixtures

  test "ordinary fixtures remain owned by the ExUnit test" do
    refute Hegel.in_property_case?()
    child = HegelFixtures.start_fixture!({Agent, fn -> :ordinary end}, id: :ordinary_fixture)
    assert Agent.get(child, & &1) == :ordinary
    assert Process.alive?(child)
    :ok = stop_supervised(:ordinary_fixture)
    refute Process.alive?(child)
  end

  property "each generated case can reuse a supervised fixture ID" do
    value = draw("value", integer())
    child = HegelFixtures.start_supervised!({Agent, fn -> value end}, id: :case_fixture)

    temporary =
      HegelFixtures.start_supervised!(
        {Task,
         fn ->
           receive do
             :done -> :ok
           end
         end},
        id: :temporary_fixture
      )

    assert Process.alive?(temporary)
    assert Agent.get(child, & &1) == value
  end

  test "failure minimization and replay clean every supervised case" do
    owner = self()

    failing = fn ->
      value = draw("value", integer(0..100))
      child = HegelFixtures.start_supervised!({Agent, fn -> value end}, id: :failing_fixture)
      send(owner, {:created, child})
      assert value < 0
    end

    # One deliberately failing input drives shrinking and replay; this is a
    # runner negative control, not a reduced domain-property budget.
    assert %{status: :failed, failures: [%{blob: blob}]} =
             Hegel.run(failing, test_cases: 1, database: :disabled, seed: 41018)

    assert_no_live_fixtures()
    assert_raise ExUnit.AssertionError, fn -> Hegel.reproduce(failing, blob) end
    assert_no_live_fixtures()
  end

  test "explicit teardown is allowed and reused IDs cannot kill a replacement" do
    assert %{status: :passed} =
             Hegel.run(
               fn ->
                 HegelFixtures.start_supervised!({Agent, fn -> :original end}, id: :stopped)
                 :ok = stop_supervised(:stopped)
               end,
               database: :disabled
             )

    owner = self()

    error =
      assert_raise ErlangError, fn ->
        Hegel.run(
          fn ->
            # Cleanup ordering stops the replacement only after the ownership
            # check has proved it cannot be mistaken for the original child.
            on_cleanup(fn ->
              receive do
                {:replacement, replacement} ->
                  send(owner, {:replacement_survived, Process.alive?(replacement)})
              after
                0 -> flunk("replacement fixture missing")
              end

              :ok = stop_supervised(:reused)
            end)

            HegelFixtures.start_supervised!({Agent, fn -> :original end}, id: :reused)
            :ok = stop_supervised(:reused)
            replacement = start_supervised!({Agent, fn -> :replacement end}, id: :reused)
            send(owner, {:replacement, replacement})
          end,
          test_cases: 1,
          database: :disabled
        )
      end

    assert inspect(error.original) =~ "different process"
    assert_receive {:replacement_survived, true}
  end

  @spec assert_no_live_fixtures() :: :ok
  defp assert_no_live_fixtures do
    receive do
      {:created, pid} ->
        refute Process.alive?(pid)
        assert_no_live_fixtures()
    after
      0 -> :ok
    end
  end
end
