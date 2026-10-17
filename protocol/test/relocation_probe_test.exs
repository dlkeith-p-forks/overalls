defmodule OverallsProtocol.RelocationProbeTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
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

  test "source installation and destination connectivity remain distinct and exactly correlated" do
    for phase <- [:grant, :probe] do
      c = command()

      endpoint =
        if phase == :probe,
          do: %{"address" => "source.example", "port" => 2222, "host_key" => c.public_key}

      c = %{c | phase: phase, source_endpoint: endpoint}

      assert {:ok, ^c} =
               c |> Codec.encode_command() |> JSON.encode!() |> JSON.decode!() |> Codec.command()

      r = Map.take(c, [:id, :phase, :challenge, :revision, :expires_at])

      assert {:ok, ^r} =
               r |> Codec.encode_result() |> JSON.encode!() |> JSON.decode!() |> Codec.result()

      assert Codec.matches?(c, r)

      for {key, value} <- [
            id: id(99),
            phase: if(phase == :grant, do: :probe, else: :grant),
            challenge: id(99),
            revision: 2,
            expires_at: c.expires_at + 1
          ] do
        refute Codec.matches?(c, Map.put(r, key, value))
      end

      wire = Codec.encode_command(c)
      for key <- Map.keys(wire), do: assert({:error, _} = Codec.command(Map.delete(wire, key)))

      for key <- ~w(path argv private_key stream extra),
          do: assert({:error, _} = Codec.command(Map.put(wire, key, "forbidden")))

      bad_endpoint =
        if phase == :grant,
          do: %{"address" => "source.example", "port" => 2222, "host_key" => c.public_key}

      assert {:error, _} = Codec.command(Map.put(wire, "source_endpoint", bad_endpoint))
    end
  end

  test "malformed identity, integers, endpoint and bounded batches fail closed" do
    wire = Codec.encode_command(command())

    for key <- ~w(generation revision expires_at),
        bad <- [nil, 0, -1, 1.0, 9_223_372_036_854_775_807],
        do: assert({:error, _} = Codec.command(Map.put(wire, key, bad)))

    for key <- ~w(id challenge),
        bad <- [nil, "", id(1) <> "\n"],
        do: assert({:error, _} = Codec.command(Map.put(wire, key, bad)))

    assert {:error, _} = Codec.command(Map.put(wire, "public_key", "private material"))
    assert {:error, _} = Codec.command(Map.put(wire, "phase", "stop"))
    assert {:error, _} = Codec.command(put_in(wire, ["intent", "version"], 2))
    assert {:error, _} = Codec.commands([wire, wire])
    assert {:ok, _} = Codec.commands(for n <- 1..16, do: Map.put(wire, "id", id(n)))
    assert {:error, _} = Codec.commands(for n <- 1..17, do: Map.put(wire, "id", id(n)))
    r = Map.take(wire, ~w(id phase challenge revision expires_at))
    assert {:error, _} = Codec.results([r, r])
    assert {:error, _} = Codec.results(for n <- 1..17, do: Map.put(r, "id", id(n)))
    message = %{"version" => 4, "session_id" => id(20), "epoch" => 1, "results" => [r]}
    assert {:ok, _} = Codec.exchange(message)
    assert {:error, :unsupported_version} = Codec.exchange(%{message | "version" => 2})
    assert {:error, _} = Codec.exchange(Map.put(message, "extra", nil))
    assert {:error, _} = Codec.exchange(%{message | "epoch" => 0})
  end

  property "arbitrary terms never produce probe authority or raise" do
    check all(value <- term()) do
      assert Codec.command(value) == {:error, :invalid_message}
      assert Codec.result(value) == {:error, :invalid_message}
    end
  end
end
