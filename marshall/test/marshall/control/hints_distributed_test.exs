defmodule Marshall.Control.HintsDistributedTest do
  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification;recovery] control-hint-cross-node-commit-gated
  # Two independent BEAMs sharing only PostgreSQL: a hint committed on one node
  # MUST reach a subscriber on the other, and a rolled-back hint MUST NOT.
  setup_all do
    peers =
      for name <- [:marshall_hints_1, :marshall_hints_2] do
        peer =
          start_supervised!(%{
            id: name,
            start:
              {:peer, :start_link,
               [
                 %{
                   name: String.to_atom("#{name}_#{System.pid()}"),
                   connection: :standard_io,
                   args: [~c"+S", ~c"2:2"],
                   wait_boot: 30_000
                 }
               ]},
            restart: :temporary
          })

        :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])

        config =
          for {app, _, _} <- Application.loaded_applications(),
              app not in [:kernel, :stdlib, :elixir, :logger],
              do: {app, Application.get_all_env(app)}

        :ok = :peer.call(peer, Application, :put_all_env, [config, [persistent: true]])

        repo =
          Application.fetch_env!(:marshall, Marshall.Repo)
          |> Keyword.put(:pool, DBConnection.ConnectionPool)
          |> Keyword.put(:pool_size, 2)

        :ok =
          :peer.call(peer, Application, :put_env, [
            :marshall,
            Marshall.Repo,
            repo,
            [persistent: true]
          ])

        :ok =
          :peer.call(peer, Application, :put_env, [:logger, :level, :error, [persistent: true]])

        {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:marshall], 30_000)
        peer
      end

    %{peers: peers}
  end

  test "a committed hint crosses nodes and a rolled-back one never does", %{peers: [a, b]} do
    committed = Ecto.UUID.generate()
    rolled_back = Ecto.UUID.generate()
    on_committed = :peer.call(b, Marshall.HintCollector, :start, [:vm, committed])
    on_rolled_back = :peer.call(b, Marshall.HintCollector, :start, [:vm, rolled_back])

    assert {:error, :test_rollback} =
             :peer.call(a, Marshall.HintCollector, :emit, [:vm, rolled_back, :rollback])

    assert {:ok, :committed} =
             :peer.call(a, Marshall.HintCollector, :emit, [:vm, committed, :commit])

    assert eventually(fn ->
             :peer.call(b, Marshall.HintCollector, :received, [on_committed]) ==
               [{:control_hint, :vm, committed}]
           end)

    # The rollback happened first; once the later commit arrived, any delivery
    # of the rolled-back hint would already have been observed.
    assert :peer.call(b, Marshall.HintCollector, :received, [on_rolled_back]) == []
  end

  @spec eventually((-> boolean()), non_neg_integer()) :: boolean()
  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && eventually(check, attempts - 1)
    end
  end
end
