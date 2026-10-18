defmodule Marshall.PropertySandboxTest do
  use ExUnit.Case, async: false
  require Hegel

  alias Ecto.Adapters.SQL.Sandbox

  # @cc [owner:ghuntley,label:verification] forced-generated-case-sandbox-release
  # Killing a generated-case process before its Hegel cleanup MUST still release
  # shared SQL ownership through ExUnit's exit callbacks before the next test.
  test "ExUnit cleanup releases a sandbox after its generated case is killed" do
    child = start_case(self())
    monitor = Process.monitor(child)
    assert_receive {:sandbox_ready, ^child}, 1_000
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, 1_000
    assert :ok = ExUnit.OnExitHandler.run(child, 1_000)

    _owner = fresh_owner()
    assert %{rows: [[1]]} = Marshall.Repo.query!("SELECT 1")
  end

  # @cc [owner:ghuntley,label:verification] completed-generated-case-owner-custody
  # An exit fallback for a normally completed case MUST NOT stop a later case's
  # shared SQL owner; cleanup is bound to the original owner PID only.
  test "a completed case fallback preserves a later sandbox owner" do
    child = start_case(self())
    monitor = Process.monitor(child)
    assert_receive {:sandbox_ready, ^child}, 1_000
    send(child, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^child, :normal}, 1_000

    _owner = fresh_owner()
    assert :ok = ExUnit.OnExitHandler.run(child, 1_000)
    assert %{rows: [[1]]} = Marshall.Repo.query!("SELECT 1")
  end

  # One case is a deliberate abrupt-exit control, not an exploration budget.
  # Register the child exactly as the pinned ExUnit runner does, so its actual
  # exit-handler boundary can be exercised without killing the containing test.
  @spec start_case(pid()) :: pid()
  defp start_case(parent) do
    start_supervised!(
      {Task,
       fn ->
         :ok = ExUnit.OnExitHandler.register(self())

         Hegel.check(
           fn ->
             :ok = Marshall.DataCase.isolate_property_case()
             send(parent, {:sandbox_ready, self()})

             receive do
               :finish -> :ok
             after
               5_000 -> flunk("generated sandbox control was not released")
             end
           end,
           test_cases: 1,
           database: :disabled,
           print_blob: false
         )
       end},
      restart: :temporary
    )
  end

  @spec fresh_owner() :: pid()
  defp fresh_owner do
    owner = Sandbox.start_owner!(Marshall.Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    owner
  end
end
