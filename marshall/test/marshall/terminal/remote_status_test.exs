defmodule Marshall.Terminal.RemoteStatusTest do
  use ExUnit.Case, async: true

  test "format_status preserves keys while redacting terminal state" do
    status =
      Marshall.Terminal.Remote.format_status(:normal, %{
        state: %{socket: "private-bytes"},
        reason: :private_reason,
        log: [:private_log],
        message: "private-message"
      })

    assert Keyword.keys(status.data) |> Enum.sort() == [:log, :message, :reason, :state]
    assert status.data[:log] == []
    assert status.data[:state] == :redacted
    assert status.data[:reason] == :redacted
    assert status.data[:message] == :redacted
    refute inspect(status) =~ "private-"
  end
end
