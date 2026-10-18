Code.require_file("../../protocol/test/support/control_close_peer.ex", __DIR__)

defmodule Ziggy.PendingVersionRefusalPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.Control.{Client, Close}
  alias OverallsProtocol.Test.ControlClosePeer

  @fixtures Path.expand("../../marshall/test/fixtures/tls", __DIR__)

  # @cc [owner:ghuntley,label:verification;recovery] ziggy-pending-version-refusal
  # Pending public calls retired by actual TLS close4001 MUST retain
  # unsupported_version; close4008 MUST remain a transient transport class.
  # A prior successful call and peer-observed pending inventory MUST establish
  # reach. Connection loss MUST NOT replay any request.
  property "pending calls retain a version refusal after the peer closes",
    profile: :ci,
    test_cases: 1 do
    supervisor = start_supervised!(Task.Supervisor)

    check all(count <- integer(1..3), max_runs: 3, max_shrinking_steps: 0) do
      for reason <- [:unsupported_version, :draining] do
        reference = make_ref()
        ca = Path.join(@fixtures, "ca.pem")

        {:ok, listener} =
          :ssl.listen(0, [
            :binary,
            active: false,
            ip: {127, 0, 0, 1},
            certfile: Path.join(@fixtures, "localhost.pem"),
            keyfile: Path.join(@fixtures, "localhost.key")
          ])

        on_exit(fn -> :ssl.close(listener) end)
        {:ok, {_, port}} = :ssl.sockname(listener)
        owner = self()
        peer_id = make_ref()

        peer =
          start_supervised!(%{
            id: peer_id,
            start:
              {Task, :start_link, [fn -> ControlClosePeer.serve(listener, owner, reference) end]},
            restart: :temporary
          })

        client_id = make_ref()
        base = "https://127.0.0.1:#{port}"

        client =
          start_supervised!(
            {Client,
             [
               url: base,
               service: "ziggy",
               credential: fn -> {:ok, "fixture-token"} end,
               bind: fn -> %{} end,
               cacertfile: ca,
               owner: self()
             ]},
            id: client_id
          )

        config = %{origin: base, token: "fixture-token", ca_file: ca, client: client}
        assert_receive {:peer_welcomed, ^reference}, 3_000
        assert_receive {:control, ^client, {:connected, _}}, 3_000

        healthy =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Ziggy.Control.request(config, "identity", %{})
          end)

        assert_receive {:peer_request, ^reference, healthy_id, "ziggy.identity"}, 2_000
        send(peer, {:reply, healthy_id, {:ok, %{}}})
        assert Task.await(healthy, 2_000) == {:ok, %{}}

        tasks =
          for _ <- 1..count,
              do:
                Task.Supervisor.async_nolink(supervisor, fn ->
                  Ziggy.Control.request(config, "identity", %{})
                end)

        ids =
          for _ <- 1..count do
            assert_receive {:peer_request, ^reference, id, "ziggy.identity"}, 2_000
            id
          end

        assert length(Enum.uniq(ids)) == count
        send(peer, {:close, Close.code(reason)})
        assert_receive {:control, ^client, {:disconnected, ^reason}}, 2_000

        expected =
          if reason == :unsupported_version,
            do: {:error, :unsupported_version},
            else: {:error, :authority_unavailable}

        assert Enum.map(tasks, &Task.await(&1, 2_000)) == List.duplicate(expected, count)
        refute_receive {:peer_request, ^reference, _, _}, 50
        :ok = stop_supervised(client_id)
        _ = stop_supervised(peer_id)
        :ssl.close(listener)
      end
    end
  end
end
