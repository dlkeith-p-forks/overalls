defmodule Marshall.CommittedFixtureCleanupTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.Compute.Ledger
  alias Marshall.GalileoPeerFixture
  alias Marshall.GuestIdentityFixture
  alias Marshall.Repo

  @type kind :: :admission | :peer | :roster
  @type inventory :: %{String.t() => [String.t()]}

  # @cc [owner:ghuntley,label:verification] committed-fixture-complete-inventory
  # Generated success and assertion-failure histories MUST restore every public
  # table's complete row digest inventory, including unrelated retained history.
  # Setup MUST use real public provisioning actions. Synthetic host receipts do
  # not establish native guest or isolation behavior.
  property "committed fixture success and failure restore the prior complete inventory",
    test_cases: 100 do
    history =
      draw(
        "history",
        shuffle(
          for kind <- [:admission, :peer, :roster],
              fail? <- [false, true] do
            {kind, fail?}
          end
        )
      )

    for control_kind <- [:unused_image, :vm], do: verify_history!(history, control_kind)
  end

  @spec verify_history!([{kind(), boolean()}], :unused_image | :vm) :: :ok
  defp verify_history!(history, control_kind) do
    unboxed(fn ->
      original = inventory()
      dispose_control = control_fixture!(control_kind)

      Cleanup.run(
        fn ->
          protected = inventory()

          for {kind, fail?} <- history do
            cleanup = fixture!(kind)

            body = fn ->
              refute inventory() == protected
              if fail?, do: flunk("intentional fixture assertion"), else: :completed
            end

            if fail? do
              assert_raise ExUnit.AssertionError, ~r/intentional fixture assertion/, fn ->
                Cleanup.run(body, cleanup)
              end
            else
              assert Cleanup.run(body, cleanup) == :completed
            end

            Marshall.CommittedFixtureInventory.assert_restored!(protected)
          end
        end,
        dispose_control
      )

      Marshall.CommittedFixtureInventory.assert_restored!(original)
    end)
  end

  test "a teardown failure retains the original assertion and both stack traces" do
    original = %ExUnit.AssertionError{message: "original fixture assertion"}
    secondary = %RuntimeError{message: "fixture teardown failed"}

    error =
      assert_raise ExUnit.MultiError, fn ->
        Cleanup.run(fn -> raise original end, fn -> raise secondary end)
      end

    assert [{:error, ^original, original_stack}, {:error, ^secondary, cleanup_stack}] =
             error.errors

    assert [{__MODULE__, _, _, _} | _] = original_stack
    assert [{__MODULE__, _, _, _} | _] = cleanup_stack
  end

  for fail? <- [false, true] do
    @recovery_failure fail?
    test "rich recovery fixture preserves unrelated history after failure=#{fail?}" do
      unboxed(fn ->
        original = inventory()
        dispose_control = control_fixture!(:vm)

        Cleanup.run(
          fn ->
            protected = inventory()
            images_before = Cleanup.fixture_image_ids()

            {:ok, {fixture, turn}} =
              Ledger.transaction(fn ->
                fixture = Marshall.AgentRevocationFixture.setup()
                {fixture, Marshall.AgentRevocationFixture.submit!(fixture)}
              end)

            cleanup = fn ->
              Marshall.AgentContextRecoveryFixture.cleanup!(
                fixture.vm.id,
                fixture.vm.host_id,
                [fixture.owner, fixture.member]
              )

              Cleanup.images!(Cleanup.fixture_image_ids() -- images_before)
            end

            body = fn ->
              Marshall.AgentContextRecoveryFixture.install_checkpoint(turn.id)
              refute inventory() == protected

              if @recovery_failure,
                do: flunk("intentional recovery fixture failure"),
                else: :completed
            end

            if @recovery_failure do
              assert_raise ExUnit.AssertionError, ~r/intentional recovery fixture failure/, fn ->
                Cleanup.run(body, cleanup)
              end
            else
              assert Cleanup.run(body, cleanup) == :completed
            end

            Marshall.CommittedFixtureInventory.assert_restored!(protected)
          end,
          dispose_control
        )

        Marshall.CommittedFixtureInventory.assert_restored!(original)
      end)
    end
  end

  test "failure stops an outstanding independent peer before deleting its fixture" do
    peer =
      start_supervised!(%{
        id: :fixture_cleanup_peer,
        start:
          {:peer, :start_link,
           [
             %{
               connection: :standard_io,
               args: [~c"+S", ~c"2:2", ~c"+SDcpu", ~c"1", ~c"+SDio", ~c"1"],
               wait_boot: 30_000
             }
           ]},
        restart: :temporary
      })

    monitor = Process.monitor(peer)
    supervisor = start_supervised!(Task.Supervisor)
    # This call cannot finish by itself. Stopping only the local caller would
    # leave its independent remote work alive.
    caller =
      Task.Supervisor.async_nolink(supervisor, fn ->
        try do
          :peer.call(peer, :timer, :sleep, [:infinity], :infinity)
        catch
          :exit, _ -> :peer_stopped
        end
      end)

    await_remote_sleep!(peer)

    assert_raise ExUnit.AssertionError, ~r/intentional peer fixture failure/, fn ->
      Cleanup.run(
        fn -> flunk("intentional peer fixture failure") end,
        fn ->
          assert_receive {:DOWN, ^monitor, :process, ^peer, _}, 1_000
          assert Task.await(caller, 1_000) == :peer_stopped
        end,
        [peer]
      )
    end
  end

  @spec await_remote_sleep!(pid(), non_neg_integer()) :: :ok
  defp await_remote_sleep!(peer, attempts \\ 100)
  defp await_remote_sleep!(_peer, 0), do: flunk("Independent peer did not enter blocked call")

  defp await_remote_sleep!(peer, attempts) do
    blocked? =
      :peer.call(peer, :erlang, :processes, [])
      |> Enum.any?(fn pid ->
        :peer.call(peer, :erlang, :process_info, [pid, :current_function]) ==
          {:current_function, {:timer, :sleep, 1}}
      end)

    if blocked? do
      :ok
    else
      receive do
      after
        10 -> await_remote_sleep!(peer, attempts - 1)
      end
    end
  end

  @spec fixture!(kind()) :: (-> term())
  defp fixture!(:admission) do
    images_before = Cleanup.fixture_image_ids()
    host = Marshall.ComputeFixtures.host_fixture()
    created_image_ids = Cleanup.fixture_image_ids() -- images_before
    owner = Marshall.ComputeFixtures.user()
    {:ok, vm} = Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: owner)
    assert vm.host_id == host.host.id

    fn ->
      Cleanup.cleanup_compute(host.host.id, owner.id)
      Cleanup.images!(created_image_ids)
    end
  end

  defp fixture!(:peer) do
    fixture = GalileoPeerFixture.create()
    fn -> GalileoPeerFixture.cleanup(fixture) end
  end

  defp fixture!(:roster) do
    fixtures = GuestIdentityFixture.roster_fixtures!()
    fn -> GuestIdentityFixture.cleanup_rosters(fixtures) end
  end

  @spec control_fixture!(:unused_image | :vm) :: (-> term())
  defp control_fixture!(:unused_image) do
    images_before = Cleanup.fixture_image_ids()
    image = Marshall.ComputeFixtures.image_fixture()
    created_image_ids = Cleanup.fixture_image_ids() -- images_before

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM compute_virtual_machines WHERE image_id=$1",
               [image.id],
               log: false
             )

    fn -> Cleanup.images!(created_image_ids) end
  end

  defp control_fixture!(:vm) do
    control = GalileoPeerFixture.create()
    Ledger.update!(control.host, :configure, %{enabled: false})
    assert_control_history!(control.vm.id)
    fn -> GalileoPeerFixture.cleanup(control) end
  end

  test "inventory diagnostics preserve duplicate hashes and empty table changes" do
    assert Marshall.CommittedFixtureInventory.difference(
             %{"rows" => ["same", "same"], "removed_empty" => []},
             %{"rows" => ["same"], "added_empty" => []}
           ) == %{
             "rows" => %{before?: true, after?: true, added: [], removed: ["same"]},
             "removed_empty" => %{before?: true, after?: false, added: [], removed: []},
             "added_empty" => %{before?: false, after?: true, added: [], removed: []}
           }
  end

  @spec assert_control_history!(String.t()) :: :ok
  defp assert_control_history!(vm_id) do
    params = [Ecto.UUID.dump!(vm_id)]

    for sql <- [
          "SELECT count(*) FROM agent_roots WHERE vm_id=$1",
          "SELECT count(*) FROM agent_threads WHERE root_id IN (SELECT id FROM agent_roots WHERE vm_id=$1)",
          "SELECT count(*) FROM agent_audit_events WHERE vm_id=$1",
          "SELECT count(*) FROM admin_job_snapshots WHERE subject_id IN (SELECT id FROM compute_operations WHERE vm_id=$1)",
          "SELECT count(*) FROM admin_job_events WHERE job_id IN (SELECT id FROM admin_job_snapshots WHERE subject_id IN (SELECT id FROM compute_operations WHERE vm_id=$1))",
          "SELECT count(*) FROM compute_lifecycle_events WHERE vm_id=$1"
        ] do
      assert %{rows: [[count]]} = Repo.query!(sql, params, log: false)
      assert count > 0
    end

    :ok
  end

  @spec inventory() :: inventory()
  defp inventory, do: Marshall.CommittedFixtureInventory.snapshot()

  @spec unboxed((-> value)) :: value when value: term()
  defp unboxed(body), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, body)
end
