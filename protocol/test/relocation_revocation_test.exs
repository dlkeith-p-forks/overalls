defmodule OverallsProtocol.RelocationRevocationTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.RelocationRevocation, as: Wire
  @id "00000000-0000-4000-8000-000000000001"
  @placement "00000000-0000-4000-8000-000000000002"
  @host "00000000-0000-4000-8000-000000000003"
  @maximum 9_223_372_036_854_775_807

  test "revocation carries only bounded authority, never credential material" do
    command = %{
      id: @id,
      host_id: @host,
      placement_id: @placement,
      execution_epoch: 1,
      expires_at: @maximum
    }

    assert {:ok, ^command} = Wire.command(Wire.encode(command))
    result = Map.take(command, [:id, :placement_id, :execution_epoch])
    assert {:ok, ^result} = Wire.result(Wire.encode(result))

    for key <- ["path", "private_key", "public_key", "source_endpoint"] do
      assert {:error, :invalid_message} =
               Wire.command(Map.put(Wire.encode(command), key, "foreign"))

      assert {:error, :invalid_message} =
               Wire.result(Map.put(Wire.encode(result), key, "foreign"))
    end

    for epoch <- [0, @maximum + 1, "2"] do
      assert {:error, :invalid_message} =
               Wire.command(Map.put(Wire.encode(command), "execution_epoch", epoch))

      assert {:error, :invalid_message} =
               Wire.result(Map.put(Wire.encode(result), "execution_epoch", epoch))
    end

    for expiry <- [0, -1, @maximum + 1, "180"] do
      assert {:error, :invalid_message} =
               Wire.command(Map.put(Wire.encode(command), "expires_at", expiry))
    end

    assert {:ok, _} = Wire.command(Map.put(Wire.encode(command), "execution_epoch", @maximum))

    assert {:error, :invalid_message} =
             Wire.command(Map.put(Wire.encode(command), "id", "../escape"))
  end

  test "exchanges reject unsupported versions, duplicate receipts and oversized batches" do
    result = %{"id" => @id, "placement_id" => @placement, "execution_epoch" => 2}

    exchange = %{
      "version" => 4,
      "session_id" => @host,
      "epoch" => @maximum,
      "results" => [result]
    }

    assert {:ok, _} = Wire.exchange(exchange)
    assert {:error, :unsupported_version} = Wire.exchange(%{exchange | "version" => 2})
    assert {:error, :invalid_message} = Wire.exchange(Map.put(exchange, "extra", true))
    assert {:error, :invalid_message} = Wire.exchange(%{exchange | "results" => [result, result]})
    assert {:error, :invalid_message} = Wire.results(List.duplicate(result, 17))
    assert {:error, :invalid_message} = Wire.commands(List.duplicate(%{}, 17))

    for epoch <- [0, @maximum + 1] do
      assert {:error, :invalid_message} = Wire.exchange(%{exchange | "epoch" => epoch})
    end
  end
end
