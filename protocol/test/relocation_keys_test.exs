defmodule OverallsProtocol.RelocationKeysTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.RelocationKeys, as: Codec

  defp id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
  defp key, do: "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 0::256>>)

  defp command,
    do: %{
      "id" => id(1),
      "host_id" => id(2),
      "placement_id" => id(3),
      "execution_epoch" => 2,
      "source_host_id" => id(4),
      "source_endpoint" => %{"address" => "source.test", "port" => 2222, "host_key" => key()}
    }

  defp result,
    do: command() |> Map.take(~w(id placement_id execution_epoch)) |> Map.put("public_key", key())

  test "closed key preparation and public results round trip through JSON" do
    assert {:ok, command} = Codec.command(command())

    assert {:ok, ^command} =
             command |> Codec.encode() |> JSON.encode!() |> JSON.decode!() |> Codec.command()

    assert {:ok, result} = Codec.result(result())

    assert {:ok, ^result} =
             result |> Codec.encode() |> JSON.encode!() |> JSON.decode!() |> Codec.result()

    assert {:ok, %{results: [^result]}} =
             Codec.exchange(%{
               "version" => 4,
               "session_id" => id(5),
               "epoch" => 1,
               "results" => [Codec.encode(result)]
             })
  end

  test "peer paths, private keys, same-host endpoints and unbounded batches are refused" do
    for field <- ["path", "private_key", "kind", "execution_epoch"] do
      assert {:error, :invalid_message} = Codec.command(Map.put(command(), field, "/tmp/peer"))
    end

    assert {:error, _} = Codec.command(Map.put(command(), "source_host_id", id(2)))

    assert {:error, _} =
             Codec.command(
               put_in(command(), ["source_endpoint", "address"], "-oProxyCommand=evil")
             )

    assert {:error, _} = Codec.result(Map.put(result(), "public_key", "PRIVATE KEY"))
    assert {:error, _} = Codec.result(Map.put(result(), "path", "/tmp"))
    assert {:error, _} = Codec.results([result(), result()])
    assert {:error, _} = Codec.commands([command(), command()])

    for epoch <- [0, 1, -1, 1.5, 9_223_372_036_854_775_808] do
      assert {:error, _} = Codec.command(Map.put(command(), "execution_epoch", epoch))
    end

    assert {:ok, values} = Codec.commands(for n <- 1..16, do: Map.put(command(), "id", id(n)))
    assert length(values) == 16
    assert {:error, _} = Codec.commands(for n <- 1..17, do: Map.put(command(), "id", id(n)))
    message = %{"version" => 4, "session_id" => id(1), "epoch" => 1, "results" => []}

    for epoch <- [0, -1, 1.5, 9_223_372_036_854_775_808] do
      assert {:error, _} = Codec.exchange(Map.put(message, "epoch", epoch))
    end

    assert {:error, :unsupported_version} = Codec.exchange(Map.put(message, "version", 2))
    assert {:error, _} = Codec.exchange(Map.put(message, "unexpected", true))
  end
end
