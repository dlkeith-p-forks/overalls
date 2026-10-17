defmodule MarshallWeb.DatabaseWaitTest do
  # No automatic sandbox: each test decides whether this process has a database.
  use ExUnit.Case, async: false

  alias MarshallWeb.DatabaseWait

  @spec socket(boolean()) :: Phoenix.LiveView.Socket.t()
  defp socket(connected?),
    do: %Phoenix.LiveView.Socket{transport_pid: if(connected?, do: self())}

  test "static renders and answering databases never wait" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

    for connected? <- [false, true] do
      started = System.monotonic_time(:millisecond)
      socket = socket(connected?)
      assert {:cont, ^socket} = DatabaseWait.on_mount(:default, %{}, %{}, socket)
      assert System.monotonic_time(:millisecond) - started < 500
    end
  end

  test "a connected mount waits a bounded time for an unanswered database, then continues" do
    previous = Application.get_env(:marshall, :live_database_wait_ms)
    Application.put_env(:marshall, :live_database_wait_ms, 1_200)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:marshall, :live_database_wait_ms, previous),
        else: Application.delete_env(:marshall, :live_database_wait_ms)
    end)

    # Without a sandbox checkout this process's database does not answer.
    refute Marshall.Repo.answers?()
    started = System.monotonic_time(:millisecond)
    socket = socket(true)
    result = DatabaseWait.on_mount(:default, %{}, %{}, socket)
    send(self(), {:waited, result, socket, System.monotonic_time(:millisecond) - started})

    assert_receive {:waited, {:cont, socket}, socket, elapsed}, 10_000
    assert elapsed >= 1_200 and elapsed < 5_000
  end
end
