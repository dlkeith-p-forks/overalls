defmodule OverallsProtocol.ReadinessTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.Readiness

  @placement "11111111-1111-4111-8111-111111111111"
  @boot "22222222-2222-4222-8222-222222222222"
  @challenge String.duplicate("a", 64)

  defp response do
    %{
      "version" => 1,
      "state" => "ready",
      "placement_id" => @placement,
      "execution_epoch" => 9,
      "boot_challenge" => @challenge,
      "boot_id" => @boot
    }
  end

  defp expectation,
    do: %{placement_id: @placement, execution_epoch: 9, boot_challenge: @challenge}

  test "the guest response verifies only the entire expected boot identity" do
    assert {:ok, @boot} = Readiness.verify(response(), expectation())

    for {field, value} <- [
          {:placement_id, @boot},
          {:execution_epoch, 10},
          {:boot_challenge, String.duplicate("b", 64)}
        ] do
      assert {:error, :stale_readiness} =
               Readiness.verify(response(), Map.put(expectation(), field, value))
    end
  end

  test "every field is required and extra fields never confer authority" do
    for field <- Map.keys(response()) do
      assert {:error, :invalid_message} = Readiness.response(Map.delete(response(), field))
    end

    for field <- ["activation", "cleanup", "host_id", "private_key"] do
      assert {:error, :invalid_message} = Readiness.response(Map.put(response(), field, true))
    end
  end

  test "invalid or absent readiness evidence fails closed" do
    for {field, values} <- [
          {"state", ["starting", "failed", nil, true]},
          {"placement_id", [nil, "../placement", String.upcase(@placement <> "a")]},
          {"execution_epoch", [0, -1, 1.0, "9", 9_223_372_036_854_775_808]},
          {"boot_challenge", [nil, "", String.duplicate("a", 63), String.duplicate("A", 64)]},
          {"boot_id", [nil, "not-a-boot", @boot <> "\n"]}
        ],
        value <- values do
      assert {:error, :invalid_message} = Readiness.response(Map.put(response(), field, value))
    end

    for version <- [nil, 0, 2, "1"] do
      assert {:error, :unsupported_version} =
               Readiness.response(Map.put(response(), "version", version))
    end
  end

  property "arbitrary peer terms never raise or become readiness" do
    check all(value <- term()) do
      assert Readiness.response(value) in [
               {:error, :invalid_message},
               {:error, :unsupported_version}
             ]
    end
  end

  property "bounded epochs and binary challenges survive JSON and exact verification" do
    check all(epoch <- integer(1..9_223_372_036_854_775_807), bytes <- binary(length: 32)) do
      challenge = Base.encode16(bytes, case: :lower)
      wire = %{response() | "execution_epoch" => epoch, "boot_challenge" => challenge}
      expected = %{expectation() | execution_epoch: epoch, boot_challenge: challenge}
      assert {:ok, @boot} = Readiness.verify(wire |> JSON.encode!() |> JSON.decode!(), expected)
    end
  end
end
