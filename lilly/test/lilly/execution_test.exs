defmodule Lilly.ExecutionTest do
  use ExUnit.Case, async: true
  import Hegel, except: [run: 2]
  import Hegel.Gen
  alias OverallsProtocol.{Machine, View}
  alias Lilly.Execution
  alias Lilly.Execution.Liveness
  alias Lilly.Network.FlowLabel

  @host "11111111-1111-4111-8111-111111111111"
  @a "22222222-2222-4222-8222-222222222222"
  @b "33333333-3333-4333-8333-333333333333"

  defp command(placement, slot, generation, kind \\ :start) do
    %{
      id: Lilly.UUID.generate(),
      host_id: @host,
      vm_id: placement,
      placement_id: placement,
      execution_epoch: 1,
      generation: generation,
      kind: kind,
      profile: :customer,
      slot: slot
    }
  end

  setup do
    view = :"execution_view_#{System.unique_integer([:positive])}"
    start_supervised!({View, name: view})
    %{view: view}
  end

  # Writers are separate processes, exactly like the Runtime and VM actors.
  defp writer, do: spawn(fn -> loop() end)

  defp loop do
    receive do
      {:run, from, fun} ->
        send(from, {:done, self(), fun.()})
        loop()
    end
  end

  defp run(pid, fun) do
    send(pid, {:run, self(), fun})
    assert_receive {:done, ^pid, result}, 1000
    result
  end

  defp later, do: System.monotonic_time(:millisecond) + 60_000

  describe "liveness machine" do
    test "every declared pair reaches its table target and every other pair is refused" do
      for {state, event, expected} <- Machine.cases(Liveness) do
        assert Liveness.target(state, event) == expected
      end
    end

    property "held rows always equal rows(state), and slowness never changes anything" do
      events = [
        :observed_booting,
        :observed_running,
        :watched,
        :inconclusive,
        :boot_failed,
        :expired,
        :revoke
      ]

      check all(sequence <- list_of(member_of(events), max_length: 120)) do
        Enum.reduce(sequence, {Liveness.new(), MapSet.new()}, fn event, {machine, rows} ->
          case Liveness.step(machine, event) do
            {:ok, next, effects} ->
              rows =
                Enum.reduce(effects, rows, fn
                  {:publish, row}, acc -> MapSet.put(acc, row)
                  {:delete, row}, acc -> MapSet.delete(acc, row)
                end)

              assert rows == MapSet.new(Liveness.rows(next.state))

              if event == :inconclusive,
                do: assert(next.state == machine.state and effects == [])

              if event == :observed_running, do: assert(next.state == :live)

              if event == :observed_booting,
                do: assert(next.state in [:booting, :live])

              if event == :boot_failed, do: refute(:live in Liveness.rows(next.state))
              {next, rows}

            {:error, :invalid_transition} ->
              assert {event, machine.state} in [
                       {:watched, :unproven},
                       {:watched, :suspect},
                       {:watched, :revoked},
                       {:expired, :unproven},
                       {:expired, :suspect},
                       {:expired, :revoked}
                     ]

              {machine, rows}
          end
        end)
      end
    end
  end

  describe "current execution reads" do
    test "require a connected runtime, identical intent and an unexpired live row", %{view: view} do
      runtime = writer()
      actor = writer()
      cmd = command(@a, 2, 1)
      executor = {:executor, :context}
      assert Execution.current(view, @a) == :error

      :ok = run(runtime, fn -> Execution.intent(view, cmd) end)
      :ok = run(actor, fn -> Execution.publish(view, :live, cmd, executor, later()) end)
      assert Execution.current(view, @a) == :error, "a disconnected runtime grants nothing"

      :ok = run(runtime, fn -> Execution.runtime_connected(view) end)

      assert {:ok, _, %{command: ^cmd, executor: ^executor, actor: ^actor}} =
               Execution.current(view, @a)

      # A superseding durable intent revokes before the actor re-observes.
      :ok = run(runtime, fn -> Execution.intent(view, command(@a, 2, 2)) end)
      assert Execution.current(view, @a) == :error
      :ok = run(runtime, fn -> Execution.intent(view, cmd) end)

      expired = System.monotonic_time(:millisecond) - 1
      :ok = run(actor, fn -> Execution.publish(view, :live, cmd, executor, expired) end)
      assert Execution.current(view, @a) == :error, "an expired observation grants nothing"

      :ok = run(actor, fn -> Execution.publish(view, :live, cmd, executor, later()) end)
      assert {:ok, _, _} = Execution.current(view, @a)
      :ok = run(runtime, fn -> Execution.runtime_disconnected(view) end)
      assert Execution.current(view, @a) == :error
    end

    test "a different process cannot write an actor's live row", %{view: view} do
      cmd = command(@a, 2, 1)
      :ok = run(writer(), fn -> Execution.publish(view, :live, cmd, {:e, :c}, later()) end)

      assert {:error, :not_owner} =
               run(writer(), fn -> Execution.publish(view, :live, cmd, {:x, :y}, later()) end)
    end

    test "actor exit removes its live row", %{view: view} do
      runtime = writer()
      actor = writer()
      cmd = command(@a, 2, 1)
      :ok = run(runtime, fn -> Execution.runtime_connected(view) end)
      :ok = run(runtime, fn -> Execution.intent(view, cmd) end)
      :ok = run(actor, fn -> Execution.publish(view, :live, cmd, {:e, :c}, later()) end)
      assert {:ok, _, _} = Execution.current(view, @a)
      ref = Process.monitor(actor)
      Process.exit(actor, :kill)
      assert_receive {:DOWN, ^ref, :process, ^actor, _}
      Process.sleep(20)
      assert Execution.current(view, @a) == :error
    end
  end

  describe "address and flow routing" do
    setup %{view: view} do
      runtime = writer()
      :ok = run(runtime, fn -> Execution.runtime_connected(view) end)
      %{runtime: runtime}
    end

    test "an address resolves only a unique current provision/start intent", ctx do
      a = command(@a, 2, 1)
      actor = writer()
      :ok = run(ctx.runtime, fn -> Execution.intent(ctx.view, a) end)
      :ok = run(actor, fn -> Execution.publish(ctx.view, :live, a, {:e, :c}, later()) end)
      assert {:ok, _, %{command: ^a}} = Execution.by_address(ctx.view, "10.10.0.2")
      assert Execution.by_address(ctx.view, "10.10.0.3") == :error

      # A second durable intent on the same address makes resolution ambiguous.
      :ok = run(ctx.runtime, fn -> Execution.intent(ctx.view, command(@b, 2, 1)) end)
      assert Execution.by_address(ctx.view, "10.10.0.2") == :error
      :ok = run(ctx.runtime, fn -> Execution.forget_intent(ctx.view, @b) end)
      assert {:ok, _, _} = Execution.by_address(ctx.view, "10.10.0.2")

      # A stop intent is not addressable.
      :ok = run(ctx.runtime, fn -> Execution.intent(ctx.view, command(@a, 2, 2, :stop)) end)
      assert Execution.by_address(ctx.view, "10.10.0.2") == :error
    end

    test "a new generation replaces only its own flow route", ctx do
      first = command(@a, 2, 1)
      other = command(@b, 3, 1)
      {:ok, old_label} = FlowLabel.token(@host, first)
      {:ok, other_label} = FlowLabel.token(@host, other)
      source = {10, 10, 0, 2}
      other_source = {10, 10, 0, 3}
      actor = writer()
      other_actor = writer()
      :ok = run(ctx.runtime, fn -> Execution.intent(ctx.view, first) end)
      :ok = run(ctx.runtime, fn -> Execution.intent(ctx.view, other) end)
      :ok = run(actor, fn -> Execution.publish(ctx.view, :live, first, {:e, :c}, later()) end)

      :ok =
        run(other_actor, fn -> Execution.publish(ctx.view, :live, other, {:e, :c}, later()) end)

      assert {:ok, _, %{command: ^first}} = Execution.by_flow(ctx.view, old_label, source)

      current = %{first | generation: 2}
      {:ok, new_label} = FlowLabel.token(@host, current)
      :ok = run(ctx.runtime, fn -> Execution.intent(ctx.view, current) end)
      :ok = run(actor, fn -> Execution.publish(ctx.view, :live, current, {:e, :c}, later()) end)
      assert Execution.by_flow(ctx.view, old_label, source) == :error
      assert {:ok, _, %{command: ^current}} = Execution.by_flow(ctx.view, new_label, source)
      assert {:ok, _, %{command: ^other}} = Execution.by_flow(ctx.view, other_label, other_source)
      assert Execution.by_flow(ctx.view, new_label, other_source) == :error

      :ok = run(ctx.runtime, fn -> Execution.intent(ctx.view, %{current | kind: :stop}) end)
      assert Execution.by_flow(ctx.view, new_label, source) == :error
    end
  end

  @tag :hegel
  test "reads equal the join of runtime, intent and live rows for any write history" do
    placements = [@a, @b]

    check all(
            ops <-
              list_of(
                one_of([
                  constant(:connect),
                  constant(:disconnect),
                  tuple(
                    {constant(:intent), member_of(placements), integer(1..3),
                     member_of([:start, :stop])}
                  ),
                  tuple({constant(:forget), member_of(placements)}),
                  tuple({constant(:live), member_of(placements), integer(1..3), boolean()}),
                  tuple({constant(:not_live), member_of(placements)})
                ]),
                max_length: 40
              ),
            test_cases: 50
          ) do
      # A fresh view per run: earlier writers' claims never leak into this one.
      view = :"execution_property_#{System.unique_integer([:positive])}"
      {:ok, view_pid} = View.start_link(name: view)
      runtime = writer()
      actors = Map.new(placements, &{&1, writer()})

      model =
        Enum.reduce(ops, %{connected: false, intents: %{}, lives: %{}}, fn op, model ->
          model = apply_op(view, runtime, actors, op, model)

          for placement <- placements do
            expected =
              with true <- model.connected,
                   {:ok, intent} <- Map.fetch(model.intents, placement),
                   {:ok, {^intent, fresh?}} <- Map.fetch(model.lives, placement),
                   true <- fresh? do
                {:ok, intent}
              else
                _ -> :error
              end

            case Execution.current(view, placement) do
              {:ok, _version, live} -> assert expected == {:ok, live.command}
              :error -> assert expected == :error
            end
          end

          model
        end)

      _ = model
      Enum.each([runtime | Map.values(actors)], &Process.exit(&1, :kill))
      Process.unlink(view_pid)
      GenServer.stop(view_pid)
    end
  end

  defp intent_for(placement, generation, kind),
    do: %{command(placement, if(placement == @a, do: 2, else: 3), generation, kind) | id: "id"}

  defp apply_op(view, runtime, _actors, :connect, model) do
    :ok = run(runtime, fn -> Execution.runtime_connected(view) end)
    %{model | connected: true}
  end

  defp apply_op(view, runtime, _actors, :disconnect, model) do
    :ok = run(runtime, fn -> Execution.runtime_disconnected(view) end)
    %{model | connected: false}
  end

  defp apply_op(view, runtime, _actors, {:intent, placement, generation, kind}, model) do
    cmd = intent_for(placement, generation, kind)
    :ok = run(runtime, fn -> Execution.intent(view, cmd) end)
    put_in(model.intents[placement], cmd)
  end

  defp apply_op(view, runtime, _actors, {:forget, placement}, model) do
    :ok = run(runtime, fn -> Execution.forget_intent(view, placement) end)
    %{model | intents: Map.delete(model.intents, placement)}
  end

  defp apply_op(view, _runtime, actors, {:live, placement, generation, fresh?}, model) do
    cmd = intent_for(placement, generation, :start)
    until = if fresh?, do: later(), else: System.monotonic_time(:millisecond) - 1
    :ok = run(actors[placement], fn -> Execution.publish(view, :live, cmd, {:e, :c}, until) end)
    put_in(model.lives[placement], {cmd, fresh?})
  end

  defp apply_op(view, _runtime, actors, {:not_live, placement}, model) do
    :ok = run(actors[placement], fn -> Execution.withdraw(view, :live, placement) end)
    %{model | lives: Map.delete(model.lives, placement)}
  end
end
