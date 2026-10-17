defmodule MarshallWeb.DatabaseWait do
  @moduledoc """
  Holds a reconnecting LiveView's mount while the database does not answer
  (ADR-0140: an unreachable database is not evidence of anything).

  A failed main-view join makes the browser reload the page, discarding live
  terminal panes whose own connections survived the outage. Waiting here keeps
  the join pending, and the existing DOM in place, until the database answers
  or `wait_ms/0` elapses; the remaining hooks then run exactly as before.
  Static (disconnected) renders never wait.
  """

  @poll_ms 500

  @doc "The longest a connected mount waits; configurable for tests only."
  @spec wait_ms() :: pos_integer()
  def wait_ms, do: Application.get_env(:marshall, :live_database_wait_ms, 40_000)

  # @cc [owner:ghuntley,label:recovery] live-mount-awaits-database
  # A connected mount MUST wait at most wait_ms/0 for Marshall.Repo.answers?/0
  # and then continue unchanged; it never grants or refuses anything itself.
  # Disconnected renders MUST NOT wait.
  @spec on_mount(atom(), map() | :not_mounted_at_router, map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket),
      do: await(System.monotonic_time(:millisecond) + wait_ms())

    {:cont, socket}
  end

  @spec await(integer()) :: :ok
  defp await(deadline) do
    cond do
      Marshall.Repo.answers?() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(@poll_ms)
        await(deadline)
    end
  end
end
