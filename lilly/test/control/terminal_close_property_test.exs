defmodule Lilly.Control.TerminalClosePropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.Control.{Client, Close}
  alias Lilly.Control.Client, as: LillyClient
  alias Lilly.Test.ControlClosePeer
  @fixtures Path.expand("../../../marshall/test/fixtures/tls", __DIR__)
  @host "00000000-0000-4000-8000-000000000001"
  @session "00000000-0000-4000-8000-000000000002"

  # @cc [owner:ghuntley,label:verification;recovery] lilly-pending-close-terminal-class
  # Actual close4001 after every pending request is observed MUST preserve the
  # terminal version class; close4008 and prior transient replies MUST remain
  # transient. Later version-refused calls MUST NOT dispatch or replay work.
  @tag :hegel
  test "pending Lilly exchanges retain terminal version refusal over actual TLS" do
    Hegel.check(
      fn ->
        prefix = draw("prefix", integer(0..2))

        for {reason, expected} <- [
              {:idle, :transport_error},
              {:unsupported_version, :unsupported_version}
            ] do
          supervisor_id = make_ref()

          supervisor =
            Overalls.HegelFixtures.start_supervised!(Task.Supervisor, id: supervisor_id)

          {:ok, listener} =
            :ssl.listen(0, [
              :binary,
              active: false,
              reuseaddr: true,
              ip: {127, 0, 0, 1},
              certfile: Path.join(@fixtures, "localhost.pem"),
              keyfile: Path.join(@fixtures, "localhost.key")
            ])

          {:ok, {_, port}} = :ssl.sockname(listener)
          reference = make_ref()
          owner = self()

          peer =
            Task.Supervisor.async_nolink(supervisor, fn ->
              ControlClosePeer.serve(listener, owner, reference)
            end)

          control_id = make_ref()
          token = @host <> ":" <> String.duplicate("a", 43)

          control =
            Overalls.HegelFixtures.start_supervised!(
              {Client,
               url: "https://127.0.0.1:#{port}",
               service: "lilly",
               credential: fn -> {:ok, token} end,
               bind: fn -> %{"host_id" => @host} end,
               cacertfile: Path.join(@fixtures, "ca.pem"),
               owner: self()},
              id: control_id
            )

          {:ok, configured} =
            LillyClient.new("https://127.0.0.1:#{port}", @host, token,
              machine_id: "sha256:" <> String.duplicate("a", 64),
              cacertfile: Path.join(@fixtures, "ca.pem")
            )

          client = %{configured | control: control}
          session = %{session_id: @session, epoch: 1}

          try do
            assert_receive {:peer_welcomed, ^reference}, 5_000
            assert_receive {:control, ^control, {:connected, _}}, 5_000

            for _ <- List.duplicate(:transient, prefix) do
              task =
                Task.Supervisor.async_nolink(supervisor, fn ->
                  LillyClient.open(client, @session)
                end)

              assert_receive {:peer_request, ^reference, id, "lilly.sessions"}, 1_000
              send(peer.pid, {:reply, id, {:error, "temporarily_unavailable"}})
              assert Task.await(task, 5_000) == {:error, :temporarily_unavailable}
            end

            tasks = [
              Task.Supervisor.async_nolink(supervisor, fn ->
                LillyClient.open(client, @session)
              end),
              Task.Supervisor.async_nolink(supervisor, fn ->
                LillyClient.exchange_execution(client, session, nil, [], [])
              end)
            ]

            operations =
              for _ <- 1..2 do
                assert_receive {:peer_request, ^reference, _id, operation}, 1_000
                operation
              end

            assert MapSet.new(operations) == MapSet.new(["lilly.sessions", "lilly.exchange"])
            send(peer.pid, {:close, Close.code(reason)})
            results = Enum.map(tasks, &Task.await(&1, 5_000))
            assert_receive {:control, ^control, {:disconnected, ^reason}}, 5_000
            assert results == List.duplicate({:error, expected}, 2)
            assert Task.await(peer, 5_000) == :ok

            if reason == :unsupported_version do
              assert Client.status(control) == {:disconnected, :unsupported_version}
              assert LillyClient.open(client, @session) == {:error, :unsupported_version}

              assert LillyClient.exchange_execution(client, session, nil, [], []) ==
                       {:error, :unsupported_version}
            end

            refute_receive {:peer_request, ^reference, _, _}, 50
          after
            :ssl.close(listener)
            stop_supervised(control_id)
            stop_supervised(supervisor_id)
          end
        end
      end,
      test_cases: 100
    )
  end
end
