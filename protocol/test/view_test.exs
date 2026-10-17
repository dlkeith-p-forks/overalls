defmodule OverallsProtocol.ViewTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.View

  @keys [:k1, :k2, :k3]
  @terms [:t1, :t2]

  setup do
    name = :"view_test_#{System.unique_integer([:positive])}"
    start_supervised!({View, name: name})
    %{view: name}
  end

  # Writers are real processes that execute commands on request, so ownership is
  # enforced exactly as in production.
  defp writer do
    spawn(fn -> loop() end)
  end

  defp loop do
    receive do
      {:run, from, fun} ->
        send(from, {:result, self(), fun.()})
        loop()
    end
  end

  defp run(pid, fun) do
    send(pid, {:run, self(), fun})

    receive do
      {:result, ^pid, result} -> result
    after
      1_000 -> flunk("writer did not answer")
    end
  end

  property "rows, ownership, versions and lookups match a reference model", %{view: view} do
    check all(
            commands <-
              list_of(
                one_of([
                  tuple({constant(:claim), integer(0..2), member_of(@keys)}),
                  tuple(
                    {constant(:put), integer(0..2), member_of(@keys), integer(),
                     list_of(member_of(@terms), max_length: 2)}
                  ),
                  tuple({constant(:delete), integer(0..2), member_of(@keys)}),
                  tuple({constant(:release), integer(0..2), member_of(@keys)}),
                  tuple({constant(:crash), integer(0..2)})
                ]),
                max_length: 60
              ),
            max_runs: 60
          ) do
      writers = Enum.map(0..2, fn _ -> writer() end)

      model =
        Enum.reduce(
          commands,
          %{owners: %{}, rows: %{}, version: current_version(view), writers: writers},
          fn command, model ->
            model = step(view, command, model)
            assert_matches(view, model)
            model
          end
        )

      Enum.each(model.writers, &Process.exit(&1, :kill))
      # Rows of exited writers disappear: the view converges to empty.
      Enum.each(@keys, fn key -> eventually(fn -> View.fetch(view, key) == :error end) end)
      # So do their claims, so the next run starts with no owners.
      await_released(view, @keys)
    end
  end

  property "subscribers are notified of every change to a subscribed key", %{view: view} do
    check all(
            ops <-
              list_of(
                one_of([
                  tuple({constant(:put), member_of(@keys)}),
                  tuple({constant(:delete), member_of(@keys)}),
                  tuple({constant(:release), member_of(@keys)}),
                  constant(:crash)
                ]),
                max_length: 30
              ),
            max_runs: 40
          ) do
      :ok = View.subscribe(view, [:k1, :k2])
      w = writer()
      Enum.each(@keys, fn key -> :ok = run(w, fn -> View.claim(view, key) end) end)

      w =
        Enum.reduce(ops, w, fn
          {:put, key}, w ->
            {:ok, _} = run(w, fn -> View.put(view, key, :v, []) end)
            expect(view, key)
            w

          {:delete, key}, w ->
            :ok = run(w, fn -> View.delete(view, key) end)
            expect(view, key)
            w

          {:release, key}, w ->
            :ok = run(w, fn -> View.release(view, key) end)
            expect(view, key)
            :ok = run(w, fn -> View.claim(view, key) end)
            w

          :crash, w ->
            Process.exit(w, :kill)
            # Every key the writer owned is removed and announced.
            Enum.each([:k1, :k2], &expect(view, &1))
            fresh = writer()

            Enum.each(@keys, fn key ->
              eventually(fn -> run(fresh, fn -> View.claim(view, key) end) == :ok end)
            end)

            fresh
        end)

      Process.exit(w, :kill)
      Enum.each([:k1, :k2], &expect(view, &1))
      refute_receive {:view_changed, ^view, :k3}, 20
    end
  end

  # Subscribed keys must be announced; unsubscribed keys never are.
  defp expect(view, key) when key in [:k1, :k2],
    do: assert_receive({:view_changed, ^view, ^key}, 500)

  defp expect(view, key), do: refute_receive({:view_changed, ^view, ^key}, 20)

  test "a restarted view starts empty", %{view: view} do
    w = writer()
    :ok = run(w, fn -> View.claim(view, :k1) end)
    {:ok, _} = run(w, fn -> View.put(view, :k1, :v, [:t1]) end)
    assert {:ok, {_, :v}} = View.fetch(view, :k1)
    pid = Process.whereis(view)
    Process.exit(pid, :kill)
    eventually(fn -> Process.whereis(view) not in [nil, pid] end)
    assert View.fetch(view, :k1) == :error
    assert View.lookup(view, :t1) == []
  end

  defp step(view, {:claim, i, key}, model) do
    pid = Enum.at(model.writers, i)
    result = run(pid, fn -> View.claim(view, key) end)

    case Map.fetch(model.owners, key) do
      {:ok, ^pid} ->
        assert result == :ok
        model

      {:ok, _other} ->
        assert result == {:error, :claimed}
        model

      :error ->
        assert result == :ok
        put_in(model.owners[key], pid)
    end
  end

  defp step(view, {:put, i, key, value, terms}, model) do
    pid = Enum.at(model.writers, i)
    result = run(pid, fn -> View.put(view, key, value, terms) end)

    if Map.get(model.owners, key) == pid do
      assert {:ok, version} = result
      assert version > model.version

      %{
        model
        | version: version,
          rows: Map.put(model.rows, key, {version, value, Enum.uniq(terms)})
      }
    else
      assert result == {:error, :not_owner}
      model
    end
  end

  defp step(view, {:delete, i, key}, model) do
    pid = Enum.at(model.writers, i)
    result = run(pid, fn -> View.delete(view, key) end)

    if Map.get(model.owners, key) == pid do
      assert result == :ok
      %{model | rows: Map.delete(model.rows, key)}
    else
      assert result == {:error, :not_owner}
      model
    end
  end

  defp step(view, {:release, i, key}, model) do
    pid = Enum.at(model.writers, i)
    result = run(pid, fn -> View.release(view, key) end)

    if Map.get(model.owners, key) == pid do
      assert result == :ok
      %{model | rows: Map.delete(model.rows, key), owners: Map.delete(model.owners, key)}
    else
      assert result == {:error, :not_owner}
      model
    end
  end

  defp step(view, {:crash, i}, model) do
    pid = Enum.at(model.writers, i)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    owned = for {key, ^pid} <- model.owners, do: key
    # The view processes the DOWN asynchronously; wait until it has. A claim
    # without a row already fetches :error, so wait for the claims as well.
    Enum.each(owned, fn key -> eventually(fn -> View.fetch(view, key) == :error end) end)
    await_released(view, owned)
    replacement = writer()

    %{
      model
      | owners: Map.drop(model.owners, owned),
        rows: Map.drop(model.rows, owned),
        writers: List.replace_at(model.writers, i, replacement)
    }
  end

  # Waits until no process holds a claim on `keys`, by claiming and releasing
  # each from a fresh probe writer.
  defp await_released(view, keys) do
    probe = writer()

    Enum.each(keys, fn key ->
      eventually(fn -> run(probe, fn -> View.claim(view, key) end) == :ok end)
      :ok = run(probe, fn -> View.release(view, key) end)
    end)

    Process.exit(probe, :kill)
  end

  defp assert_matches(view, model) do
    for key <- @keys do
      case Map.fetch(model.rows, key) do
        {:ok, {version, value, _terms}} -> assert View.fetch(view, key) == {:ok, {version, value}}
        :error -> assert View.fetch(view, key) == :error
      end
    end

    for term <- @terms do
      expected =
        for {key, {version, value, terms}} <- model.rows, term in terms, do: {key, version, value}

      assert Enum.sort(View.lookup(view, term)) == Enum.sort(expected)
    end
  end

  defp current_version(_view), do: 0

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not reached")

      true ->
        Process.sleep(5)
        eventually(fun, attempts - 1)
    end
  end
end
