defmodule Porsche.ConnectionDiagnosticsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  @id "11111111-1111-4111-8111-111111111111"

  test "session close success requires the exact affirmative acknowledgement" do
    for response <- [
          {:error, :transport_error},
          {:ok, %{}},
          {:ok, %{"session_id" => "other", "closed" => true}}
        ] do
      log =
        capture_log(fn ->
          assert :ok = Porsche.Connection.terminate(:normal, state(response))
        end)

      assert log =~ "Marshall session close unconfirmed"
      refute log =~ "Marshall session closed"
    end

    log =
      capture_log(fn ->
        assert :ok =
                 Porsche.Connection.terminate(
                   :normal,
                   state({:ok, %{"session_id" => @id, "closed" => true}})
                 )
      end)

    assert log =~ "Marshall session closed"
    refute log =~ "unconfirmed"
  end

  @spec state(term()) :: map()
  defp state(response),
    do: %{
      session: %{"session_id" => @id, "session_token" => "private-canary"},
      client: nil,
      request: fn _, "close", _ -> response end
    }
end
