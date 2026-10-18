defmodule Overalls.RequestAccounting.ProducerHistoryTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Overalls.RequestAccounting.{Config, Producer, QualityMarker}
  @name ClientHistoryFixture
  @type fixture :: %{client: pid(), owner: pid(), recorder: pid()}

  # @cc [owner:ghuntley,label:verification;security] client-live-worker-ticket-custody
  # Foreign completion or a death tuple for a live/different worker MUST retain
  # the pending admission until its issuer or worker completes it exactly once.
  property "live worker tickets survive foreign completion and death tuples until authorized settlement" do
    prefix =
      draw(
        "prefix",
        list_of(member_of([:foreign_finish, :wrong_owner_down, :live_owner_down]),
          min_length: 1,
          max_length: 10
        )
      )

    outcome = draw("outcome", member_of([:success, :failure, :exclude]))
    finisher = draw("finisher", member_of([:issuer, :worker]))
    duration = draw("duration", integer(0..10000))
    repeats = draw("repeats", integer(1..4))

    with_fixture(fn fixture ->
      ticket = Producer.admit(@name, fixture.owner)
      assert is_reference(ticket)

      for action <- [:foreign_finish, :wrong_owner_down, :live_owner_down] ++ prefix do
        foreign =
          Task.async(fn ->
            case action do
              :foreign_finish ->
                Producer.complete(@name, ticket, :failure, 999)

              :wrong_owner_down ->
                send(fixture.client, {:DOWN, ticket, :process, self(), :killed})

              :live_owner_down ->
                send(fixture.client, {:DOWN, ticket, :process, fixture.owner, :killed})
            end
          end)

        Task.await(foreign)
        assert map_size(:sys.get_state(fixture.client).pending) == 1
        assert Process.alive?(fixture.owner)
        assert finishes(fixture.recorder) == []
      end

      case finisher do
        :issuer ->
          Producer.complete(@name, ticket, outcome, duration)

        :worker ->
          send(fixture.owner, {:finish, ticket, outcome, duration, self()})
          assert_receive {:finished, owner} when owner == fixture.owner
      end

      assert map_size(:sys.get_state(fixture.client).pending) == 0

      assert [
               %{
                 "op" => "finish",
                 "id" => 1,
                 "outcome" => Atom.to_string(outcome),
                 "duration_us" => duration
               }
             ] == finishes(fixture.recorder)

      for _ <- 1..repeats do
        Producer.complete(@name, ticket, :failure, 999)
        send(fixture.client, {:DOWN, ticket, :process, fixture.owner, :killed})
        assert map_size(:sys.get_state(fixture.client).pending) == 0
      end

      monitor = Process.monitor(fixture.owner)
      Process.exit(fixture.owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, _owner, :killed}
      assert map_size(:sys.get_state(fixture.client).pending) == 0
      assert length(finishes(fixture.recorder)) == 1
      :ok
    end)
  end

  # @cc [owner:ghuntley,label:verification;reliability] client-actual-death-terminal-once
  # Confirmed worker death MUST settle one failure; later issuer completion MUST
  # neither change its outcome nor emit another duration or completion.
  property "actual worker death settles once and later issuer completion cannot change its outcome" do
    repeats = draw("repeats", integer(1..5))
    duration = draw("duration", integer(0..10000))

    with_fixture(fn fixture ->
      ticket = Producer.admit(@name, fixture.owner)
      monitor = Process.monitor(fixture.owner)
      Process.exit(fixture.owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, _owner, :killed}
      # DOWN to the client and this test have separate recipients; explicitly
      # observe client processing before treating the death as settled.
      await_empty(fixture.client, System.monotonic_time(:millisecond) + 1_000)

      assert [%{"op" => "finish", "id" => 1, "outcome" => "failure", "duration_us" => measured}] =
               finishes(fixture.recorder)

      assert is_integer(measured) and measured >= 0
      for _ <- 1..repeats, do: Producer.complete(@name, ticket, :success, duration)
      assert map_size(:sys.get_state(fixture.client).pending) == 0
      assert length(finishes(fixture.recorder)) == 1
      :ok
    end)
  end

  # @cc [owner:ghuntley,label:verification;reliability] client-finish-death-race-once
  # Racing issuer completion and actual worker death MUST produce one terminal
  # RPC for the admission. Either winner is valid; duplicates MUST NOT alter it.
  property "racing issuer completion and actual worker death record one terminal outcome" do
    duration = draw("duration", integer(0..10000))
    finish_delay = draw("finish_delay", integer(0..2))
    death_delay = draw("death_delay", integer(0..2))

    with_fixture(fn fixture ->
      ticket = Producer.admit(@name, fixture.owner)
      monitor = Process.monitor(fixture.owner)

      killer =
        Task.async(fn ->
          receive do
            :go ->
              Process.sleep(death_delay)
              Process.exit(fixture.owner, :kill)
          end
        end)

      send(killer.pid, :go)
      Process.sleep(finish_delay)
      Producer.complete(@name, ticket, :success, duration)
      Task.await(killer)
      assert_receive {:DOWN, ^monitor, :process, _owner, :killed}
      await_empty(fixture.client, System.monotonic_time(:millisecond) + 1_000)
      assert [completion] = finishes(fixture.recorder)
      assert completion["id"] == 1
      assert completion["outcome"] in ["success", "failure"]

      if completion["outcome"] == "success" do
        assert completion["duration_us"] == duration
      else
        assert is_integer(completion["duration_us"]) and completion["duration_us"] >= 0
      end

      Producer.complete(@name, ticket, :failure, 999)
      send(fixture.client, {:DOWN, ticket, :process, fixture.owner, :killed})
      assert map_size(:sys.get_state(fixture.client).pending) == 0
      assert finishes(fixture.recorder) == [completion]
      assert :sys.get_state(fixture.client).gap == false
      :ok
    end)
  end

  @spec await_empty(pid(), integer()) :: :ok
  defp await_empty(client, deadline) do
    if map_size(:sys.get_state(client).pending) == 0 do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline

      receive do
      after
        1 -> await_empty(client, deadline)
      end
    end
  end

  @spec finishes(pid()) :: [map()]
  defp finishes(recorder),
    do: Agent.get(recorder, &Enum.filter(&1, fn command -> command["op"] == "finish" end))

  @spec worker() :: :ok
  defp worker do
    receive do
      {:finish, ticket, outcome, duration, observer} ->
        Producer.complete(@name, ticket, outcome, duration)
        send(observer, {:finished, self()})
        worker()

      :stop ->
        :ok
    end
  end

  @spec serve(:gen_tcp.socket(), pid()) :: no_return()
  defp serve(listener, recorder) do
    {:ok, connection} = :gen_tcp.accept(listener)
    {:ok, bytes} = :gen_tcp.recv(connection, 0, 1_000)
    %{"version" => 1, "command" => command} = JSON.decode!(bytes)
    Agent.update(recorder, &(&1 ++ [command]))

    reply =
      case command["op"] do
        "admit" -> %{status: "admitted", id: 1}
        op when op in ["hello", "gap", "finish"] -> %{status: "ok"}
      end

    :ok = :gen_tcp.send(connection, JSON.encode!(reply))
    :ok = :gen_tcp.close(connection)
    serve(listener, recorder)
  end

  @spec stop_fixture_process(pid()) :: :ok
  defp stop_fixture_process(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      1_000 -> flunk("fixture process did not stop")
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] client-fixture-acquisition-custody
  # Every acquired socket, process and temporary directory MUST have cleanup
  # before acquiring the next resource. Worker/server cleanup MUST confirm death.
  @spec with_fixture((fixture() -> :ok)) :: :ok
  defp with_fixture(test) do
    root = Path.join(System.tmp_dir!(), "slo-history-#{System.unique_integer([:positive])}")
    File.mkdir!(root)

    try do
      File.chmod!(root, 0o700)
      :ok = QualityMarker.write(root, :clean)
      socket = Path.join(root, "rpc.sock")

      {:ok, listener} =
        :gen_tcp.listen(0, [
          :binary,
          active: false,
          packet: 4,
          packet_size: 512,
          ifaddr: {:local, socket}
        ])

      try do
        {:ok, recorder} = Agent.start(fn -> [] end)

        try do
          server = spawn(fn -> serve(listener, recorder) end)

          try do
            owner = spawn(&worker/0)

            try do
              {:ok, client} =
                Producer.start_link(Config.new!(name: @name, socket: socket, directory: root))

              try do
                test.(%{client: client, owner: owner, recorder: recorder})
              after
                if Process.alive?(client), do: GenServer.stop(client)
              end
            after
              stop_fixture_process(owner)
            end
          after
            stop_fixture_process(server)
          end
        after
          if Process.alive?(recorder), do: Agent.stop(recorder)
        end
      after
        :gen_tcp.close(listener)
      end
    after
      File.rm_rf!(root)
    end
  end
end
