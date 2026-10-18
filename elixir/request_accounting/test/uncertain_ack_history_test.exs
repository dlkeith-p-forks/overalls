defmodule Overalls.RequestAccounting.UncertainAckHistoryTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Overalls.RequestAccounting.{Config, Producer, QualityMarker}
  @name UncertainAckFixture
  @maximum 9_223_372_036_854_775_807
  @type fault :: :drop | :malformed | :refused
  @type command :: %{String.t() => String.t() | non_neg_integer()}
  @type peer_state :: %{
          commands: [command()],
          next_id: pos_integer(),
          fault: {String.t(), fault()} | nil
        }
  @type fixture :: %{client: pid(), recorder: pid(), directory: String.t()}

  # @cc [owner:ghuntley,label:verification;reliability] measurement-failure-preserves-work
  # Lost measurement acknowledgments MUST preserve the work's exact return,
  # error, throw or exit and single invocation, while retaining a recording gap.
  property "measurement acknowledgment loss preserves eligible work semantics" do
    boundary = draw("boundary", member_of(["admit", "finish"]))
    failure = draw("failure", member_of([:drop, :malformed, :refused]))
    mode = draw("mode", member_of([:return, :error, :throw, :exit]))
    value = draw("value", member_of([0, 1, 4096, @maximum]))

    with_fixture(fn fixture ->
      fault(fixture.recorder, {boundary, failure})
      reference = make_ref()

      work = fn ->
        send(self(), {reference, value})

        case mode do
          :return -> {:owned_result, value}
          :error -> :erlang.error({:owned_error, value})
          :throw -> throw({:owned_throw, value})
          :exit -> exit({:owned_exit, value})
        end
      end

      measured = fn -> Producer.measure(@name, work, fn _ -> :success end) end

      case mode do
        :return -> assert measured.() == {:owned_result, value}
        :error -> assert catch_error(measured.()) == {:owned_error, value}
        :throw -> assert catch_throw(measured.()) == {:owned_throw, value}
        :exit -> assert catch_exit(measured.()) == {:owned_exit, value}
      end

      assert_receive {^reference, ^value}
      refute_receive {^reference, _}, 0
      assert :sys.get_state(fixture.client).pending == %{}
      assert :sys.get_state(fixture.client).gap
      assert QualityMarker.read(fixture.directory) == {:ok, :gap}

      if boundary == "admit" do
        assert commands(fixture.recorder, "finish") == []
      else
        assert [terminal] = commands(fixture.recorder, "finish")
        assert terminal["id"] == 1
        assert terminal["outcome"] == if(mode == :return, do: "success", else: "failure")
        assert is_integer(terminal["duration_us"])
        assert terminal["duration_us"] >= 0 and terminal["duration_us"] <= @maximum
      end

      :ok
    end)
  end

  # @cc [owner:ghuntley,label:verification;reliability] uncertain-ack-gap-before-recovery
  # An unacknowledged admission MUST yield no ticket; an unacknowledged terminal
  # MUST not be replayed by duplicate completion. Both MUST persist a gap until
  # a gap handshake succeeds, refusing new admissions while it cannot succeed.
  property "uncertain admission and completion acknowledgments preserve gaps until verified recovery" do
    boundary = draw("boundary", member_of([:admit, :finish]))
    failure = draw("failure", member_of([:drop, :malformed, :refused]))

    recovery_failures =
      draw(
        "recovery_failures",
        list_of(member_of([:drop, :malformed, :refused]), min_length: 1, max_length: 4)
      )

    outcome = draw("outcome", member_of([:success, :failure, :exclude]))
    duration = draw("duration", member_of([0, 1, 10000, @maximum]))
    duplicates = draw("duplicates", member_of([1, 2, 4]))

    with_fixture(fn fixture ->
      case boundary do
        :admit ->
          fault(fixture.recorder, {"admit", failure})
          assert :unrecorded = Producer.admit(@name)
          assert commands(fixture.recorder, "finish") == []

        :finish ->
          ticket = Producer.admit(@name)
          assert is_reference(ticket)
          fault(fixture.recorder, {"finish", failure})
          assert :ok = Producer.complete(@name, ticket, outcome, duration)
          original = commands(fixture.recorder, "finish")

          assert original == [
                   %{
                     "op" => "finish",
                     "id" => 1,
                     "outcome" => Atom.to_string(outcome),
                     "duration_us" => duration
                   }
                 ]

          for _ <- 1..duplicates do
            :ok = Producer.complete(@name, ticket, :failure, 999)
            assert commands(fixture.recorder, "finish") == original
          end
      end

      assert :sys.get_state(fixture.client).pending == %{}
      assert :sys.get_state(fixture.client).gap
      assert QualityMarker.read(fixture.directory) == {:ok, :gap}
      admissions = commands(fixture.recorder, "admit")

      for recovery_failure <- recovery_failures do
        fault(fixture.recorder, {"gap", recovery_failure})
        assert :unrecorded = Producer.admit(@name)
        assert commands(fixture.recorder, "admit") == admissions
        assert :sys.get_state(fixture.client).pending == %{}
        assert :sys.get_state(fixture.client).gap
        assert QualityMarker.read(fixture.directory) == {:ok, :gap}
      end

      before_recovery = Agent.get(fixture.recorder, & &1.commands)
      fault(fixture.recorder, nil)
      ticket = Producer.admit(@name)
      assert is_reference(ticket)
      assert not :sys.get_state(fixture.client).gap
      assert QualityMarker.read(fixture.directory) == {:ok, :running}
      assert map_size(:sys.get_state(fixture.client).pending) == 1
      after_recovery = Agent.get(fixture.recorder, & &1.commands)

      assert Enum.drop(after_recovery, length(before_recovery)) == [
               %{"op" => "gap"},
               %{"op" => "admit"}
             ]

      assert :ok = Producer.complete(@name, ticket, :success, 1)
      assert :sys.get_state(fixture.client).pending == %{}

      assert List.last(commands(fixture.recorder, "finish")) == %{
               "op" => "finish",
               "id" => 2,
               "outcome" => "success",
               "duration_us" => 1
             }

      :ok
    end)
  end

  @spec fault(pid(), {String.t(), fault()} | nil) :: :ok
  defp fault(peer, value), do: Agent.update(peer, &%{&1 | fault: value})

  @spec commands(pid(), String.t()) :: [command()]
  defp commands(peer, op),
    do: Agent.get(peer, &Enum.filter(&1.commands, fn command -> command["op"] == op end))

  @spec serve(:gen_tcp.socket(), pid()) :: no_return()
  defp serve(listener, peer) do
    {:ok, connection} = :gen_tcp.accept(listener)
    {:ok, bytes} = :gen_tcp.recv(connection, 0, 1_000)
    %{"version" => 1, "command" => command} = JSON.decode!(bytes)
    true = is_map(command)

    true =
      Enum.all?(command, fn {key, value} ->
        is_binary(key) and (is_binary(value) or (is_integer(value) and value >= 0))
      end)

    operation = Map.fetch!(command, "op")
    true = operation in ["admit", "finish", "gap", "hello"]

    {reply, selected_fault} =
      Agent.get_and_update(peer, fn state ->
        reply =
          if command["op"] == "admit",
            do: %{status: "admitted", id: state.next_id},
            else: %{status: "ok"}

        selected =
          case state.fault do
            {^operation, failure} -> failure
            _ -> nil
          end

        next_id = if command["op"] == "admit", do: state.next_id + 1, else: state.next_id
        {{reply, selected}, %{state | commands: state.commands ++ [command], next_id: next_id}}
      end)

    case selected_fault do
      :drop -> :ok
      :malformed -> :ok = :gen_tcp.send(connection, ~s({"status":"ok","extra":1}))
      :refused -> :ok = :gen_tcp.send(connection, ~s({"status":"refused","reason":"storage"}))
      nil -> :ok = :gen_tcp.send(connection, JSON.encode!(reply))
    end

    :ok = :gen_tcp.close(connection)
    serve(listener, peer)
  end

  @spec stop_process(pid()) :: :ok
  defp stop_process(pid) do
    reference = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^reference, :process, ^pid, _reason}, 1_000
    :ok
  end

  # @cc [owner:ghuntley,label:verification;recovery] uncertain-ack-fixture-custody
  # Every acquired directory, listener and process MUST have cleanup before the
  # next acquisition. Peer cleanup MUST confirm actual process death.
  @spec with_fixture((fixture() -> :ok)) :: :ok
  defp with_fixture(test) do
    directory =
      Path.join(System.tmp_dir!(), "slo-uncertain-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)

    try do
      File.chmod!(directory, 0o700)
      :ok = QualityMarker.write(directory, :clean)
      socket = Path.join(directory, "rpc.sock")

      {:ok, listener} =
        :gen_tcp.listen(0, [
          :binary,
          active: false,
          packet: 4,
          packet_size: 512,
          ifaddr: {:local, socket}
        ])

      try do
        {:ok, peer} = Agent.start(fn -> %{commands: [], next_id: 1, fault: nil} end)

        try do
          server = spawn(fn -> serve(listener, peer) end)

          try do
            {:ok, client} =
              Producer.start_link(Config.new!(name: @name, socket: socket, directory: directory))

            try do
              test.(%{client: client, recorder: peer, directory: directory})
            after
              if Process.alive?(client), do: GenServer.stop(client)
            end
          after
            stop_process(server)
          end
        after
          if Process.alive?(peer), do: Agent.stop(peer)
        end
      after
        :gen_tcp.close(listener)
      end
    after
      File.rm_rf!(directory)
    end
  end
end
