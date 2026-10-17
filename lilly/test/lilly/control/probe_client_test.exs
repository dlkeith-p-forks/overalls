defmodule Lilly.Control.ProbeClientTest do
  use ExUnit.Case, async: true
  alias Lilly.Control.Client
  alias OverallsProtocol.RelocationProbe, as: Codec
  defp id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(to_string(n), 12, "0")

  defp command do
    %{
      id: id(1),
      generation: 1,
      phase: :grant,
      challenge: id(10),
      source_endpoint: nil,
      revision: 1,
      expires_at: 1_900_000_000,
      public_key: "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 0::256>>),
      intent: %{
        relocation_id: id(2),
        vm_id: id(3),
        source_epoch: 1,
        destination_epoch: 2,
        source: %{placement_id: id(4), host_id: id(5), pool_id: id(6)},
        destination: %{placement_id: id(7), host_id: id(8), pool_id: id(9)},
        workload: %{
          image_id: "sha256:" <> String.duplicate("a", 64),
          architecture: :x86_64,
          profile: :customer,
          slot: 2,
          vcpu: 1,
          memory_bytes: 536_870_912,
          disk_bytes: 2_147_483_648
        }
      }
    }
  end

  defp exchange(host, commands, results, change \\ & &1) do
    session = %{session_id: id(50), epoch: 1}

    response =
      %{
        "version" => 4,
        "host_id" => host,
        "session_id" => session.session_id,
        "epoch" => 1,
        "commands" => Enum.map(commands, &Codec.encode_command/1),
        "acknowledgements" => Enum.map(results, & &1.id)
      }
      |> change.()

    test = self()
    expected = Enum.map(results, &Codec.encode_result/1)

    {port, listener} =
      Lilly.Test.ControlStub.start(fn op, body ->
        send(test, {:control_request, op, body["results"] == expected})
        {:reply, {:ok, response}}
      end)

    {:ok, client} =
      Client.new("http://127.0.0.1:#{port}", host, host <> ":" <> String.duplicate("a", 43),
        allow_insecure_loopback: true,
        protocol_version: 4,
        machine_id: "sha256:" <> String.duplicate("a", 64)
      )

    client = Lilly.Test.ControlStub.connected(client)

    try do
      result = Client.exchange_relocation_probe(client, session, results)
      assert_receive {:control_request, "lilly.relocation_probe", true}, 5_000
      result
    after
      :gen_tcp.close(listener)
    end
  end

  test "source and destination commands select only their authenticated endpoint" do
    grant = command()

    probe = %{
      grant
      | phase: :probe,
        source_endpoint: %{
          "address" => "source.example",
          "port" => 2222,
          "host_key" => grant.public_key
        }
    }

    for {c, host, foreign} <- [
          {grant, grant.intent.source.host_id, grant.intent.destination.host_id},
          {probe, probe.intent.destination.host_id, probe.intent.source.host_id}
        ] do
      result = Map.take(c, [:id, :phase, :challenge, :revision, :expires_at])
      assert {:ok, %{commands: [^c], acknowledgements: [id]}} = exchange(host, [c], [result])
      assert id == c.id
      assert {:error, :invalid_message} = exchange(foreign, [c], [])

      for change <- [
            &Map.put(&1, "host_id", foreign),
            &Map.put(&1, "epoch", 2),
            &Map.put(&1, "session_id", id(99)),
            &Map.put(&1, "extra", nil),
            &Map.put(&1, "acknowledgements", [id(99)]),
            &Map.put(&1, "acknowledgements", [c.id, c.id])
          ] do
        assert {:error, :invalid_message} = exchange(host, [c], [result], change)
      end
    end
  end

  test "probe fencing notifies its owner and ignores retired runtime messages" do
    ref = make_ref()

    state = %{
      mode: :probe,
      task: %Task{ref: ref, pid: self(), owner: self(), mfa: {__MODULE__, :fixture, []}},
      owner: self(),
      pending: %{id(1) => :retained}
    }

    assert {:noreply, next} =
             Lilly.Transfer.SourceRuntime.handle_info({ref, {:error, :stale_connection}}, state)

    assert next.pending == state.pending
    assert next.task == nil
    assert_receive {:transfer_probe_fenced, _, :stale_connection}
    fenced = %{phase: :fenced, transfer_probe: nil}

    assert {:noreply, ^fenced} =
             Lilly.Control.Runtime.handle_info(
               {:transfer_probe_fenced, self(), :unauthorized},
               fenced
             )
  end
end
