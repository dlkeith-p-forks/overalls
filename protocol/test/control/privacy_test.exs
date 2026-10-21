defmodule OverallsProtocol.Control.PrivacyTest do
  use ExUnit.Case, async: true

  alias OverallsProtocol.Control.Client

  test "OTP status excludes configured endpoints and buffered application bytes" do
    client =
      start_supervised!(
        {Client,
         url: "https://private-endpoint-canary.invalid",
         service: "galileo",
         credential: fn -> {:error, :unavailable} end,
         bind: fn -> %{} end}
      )

    :sys.replace_state(client, fn state ->
      Map.put(state, :fixture_payload, "buffered-private-canary")
    end)

    status = client |> :sys.get_status() |> inspect()
    assert status =~ "redacted"
    refute status =~ "private-endpoint-canary"
    refute status =~ "buffered-private-canary"
    assert {:disconnected, _} = Client.status(client)
    refute Client.ready?(client)
  end

  test "crash formatting drops reason and message as well as state" do
    assert Client.format_status(%{
             state: %{token: "private-canary"},
             message: {:request, "private-canary"},
             reason: "private-canary"
           }) == %{state: :redacted, message: :redacted, reason: :redacted}
  end
end
