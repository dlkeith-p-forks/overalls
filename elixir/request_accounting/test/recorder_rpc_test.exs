defmodule Overalls.RequestAccounting.RecorderRPCTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Overalls.RequestAccounting.RecorderRPC

  property "admission acknowledgments are positive bounded integers only" do
    check all(identifier <- integer(-100..9_223_372_036_854_775_908)) do
      reply = JSON.encode!(%{status: "admitted", id: identifier})

      expected =
        if identifier in 1..9_223_372_036_854_775_807,
          do: {:admitted, identifier},
          else: {:error, :unavailable}

      assert RecorderRPC.decode(reply) == expected
    end
  end

  property "extra acknowledgment fields never confer durable authority" do
    check all(
            key <- string(:alphanumeric, min_length: 1, max_length: 40),
            key != "status"
          ) do
      assert {:error, :unavailable} =
               RecorderRPC.decode(JSON.encode!(%{"status" => "ok", key => 1}))
    end
  end

  test "malformed, oversize and unknown refusal replies remain closed" do
    for bytes <- [
          "{",
          String.duplicate("x", 513),
          ~s({"status":"refused","reason":"remote"}),
          ~s({"status":"admitted","id":"1"})
        ] do
      assert {:error, :unavailable} = RecorderRPC.decode(bytes)
    end

    assert :ok = RecorderRPC.decode(~s({"status":"ok"}))
    assert {:error, :refused} = RecorderRPC.decode(~s({"status":"refused","reason":"capacity"}))
  end

  test "invalid call input fails closed before opening a socket" do
    assert {:error, :unavailable} = RecorderRPC.call("relative.sock", %{op: :hello})
    assert {:error, :unavailable} = RecorderRPC.call("/tmp/socket", %{op: :unknown})
    assert {:error, :unavailable} = RecorderRPC.call("/tmp/socket", %{op: :finish, id: 0})
  end

  test "producer public input fails closed" do
    assert :unrecorded = Overalls.RequestAccounting.Producer.admit(:missing, :not_a_pid)
    assert :ok = Overalls.RequestAccounting.Producer.complete(:missing, :bad_ticket, :unknown, -1)
  end
end
