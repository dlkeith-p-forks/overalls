defmodule Marshall.HintCollector do
  @moduledoc "Test-only collector of control hints on a (peer) node."

  @spec start(Marshall.Control.Hints.kind(), String.t()) :: pid()
  def start(kind, id) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Marshall.Control.Hints.subscribe(kind, id)
        send(parent, {:subscribed, self()})
        loop([])
      end)

    receive do
      {:subscribed, ^pid} -> pid
    after
      5_000 -> raise "hint collector did not subscribe"
    end
  end

  @spec received(pid()) :: [term()]
  def received(pid) do
    ref = make_ref()
    send(pid, {:dump, self(), ref})

    receive do
      {^ref, hints} -> hints
    after
      5_000 -> raise "hint collector did not answer"
    end
  end

  @spec loop([term()]) :: no_return()
  defp loop(hints) do
    receive do
      {:dump, from, ref} ->
        send(from, {ref, Enum.reverse(hints)})
        loop(hints)

      hint ->
        loop([hint | hints])
    end
  end

  @doc "Commits (or rolls back) a transaction that emits one hint."
  @spec emit(Marshall.Control.Hints.kind(), String.t(), :commit | :rollback) :: term()
  def emit(kind, id, outcome) do
    Marshall.Repo.transaction(fn ->
      :ok = Marshall.Control.Hints.notify(kind, id)
      if outcome == :rollback, do: Marshall.Repo.rollback(:test_rollback), else: :committed
    end)
  end
end
