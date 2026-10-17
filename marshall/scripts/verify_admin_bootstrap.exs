# @cc [owner:ghuntley,label:verification;security] bootstrap-race-fresh-fixture
# This probe MUST refuse non-test or populated databases. It MUST race three
# independent Marshall instances against committed state and report only bounded
# outcomes, never sign-in tokens. It MUST NOT reset bootstrap or delete accounts.
unless Mix.env() == :test and
         String.starts_with?(
           Application.fetch_env!(:marshall, Marshall.Repo)[:database],
           "marshall_testadminbootstrap"
         ),
       do: raise("requires a dedicated marshall_testadminbootstrap fixture")

Ecto.Adapters.SQL.Sandbox.mode(Marshall.Repo, :auto)
Logger.configure(level: :error)
Logger.metadata(marshall_authentication: true)

%{rows: [[0]]} =
  Ecto.Adapters.SQL.query!(Marshall.Repo, "SELECT count(*) FROM users", [], log: false)

[%{completed: false}] = Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap)

specs =
  for index <- 1..3 do
    %{
      id: index,
      start:
        {:peer, :start_link,
         [
           %{
             name: String.to_atom("admin_bootstrap_#{index}_#{System.pid()}"),
             connection: :standard_io,
             args: [~c"+S", ~c"2:2", ~c"+SDcpu", ~c"1", ~c"+SDio", ~c"1"],
             wait_boot: 30_000
           }
         ]},
      restart: :temporary
    }
  end

{:ok, supervisor} = Supervisor.start_link(specs, strategy: :one_for_one)

try do
  config =
    for {app, _, _} <- Application.loaded_applications(),
        app not in [:kernel, :stdlib, :elixir, :logger],
        do: {app, Application.get_all_env(app)}

  peers = for {_, peer, _, _} <- Supervisor.which_children(supervisor), do: peer

  for peer <- peers do
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    :ok = :peer.call(peer, Application, :put_all_env, [config, [persistent: true]])
    :ok = :peer.call(peer, Application, :put_env, [:logger, :level, :error, [persistent: true]])

    repo_config =
      Application.fetch_env!(:marshall, Marshall.Repo)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 4)

    :ok =
      :peer.call(peer, Application, :put_env, [
        :marshall,
        Marshall.Repo,
        repo_config,
        [persistent: true]
      ])

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:marshall], 30_000)
  end

  3 = peers |> Enum.map(&:peer.call(&1, :erlang, :node, [])) |> Enum.uniq() |> length()
  strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)

  inputs =
    for index <- 1..3 do
      {:ok, token} =
        AshAuthentication.Strategy.MagicLink.request_token_for_identity(
          strategy,
          "bootstrap-#{System.pid()}-#{index}@example.test"
        )

      Ash.Changeset.for_create(Marshall.Accounts.User, :sign_in_with_magic_link, %{token: token},
        context: %{private: %{ash_authentication?: true}}
      )
    end

  results =
    Enum.zip(peers, inputs)
    |> Task.async_stream(fn {peer, input} -> :peer.call(peer, Ash, :create, [input], 30_000) end,
      max_concurrency: 3,
      timeout: 35_000
    )
    |> Enum.map(fn
      {:ok, {:ok, user}} -> user
      _ -> raise "bootstrap registration failed (details withheld)"
    end)

  1 = Enum.count(results, & &1.administrator)
  [%{completed: true}] = Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap)
  [%{kind: :bootstrap}] = Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminEvent)

  for peer <- peers do
    allowed =
      for user <- results do
        :peer.call(peer, Marshall.Authorization.Cedar, :allowed?, [
          user,
          "admin_accounts",
          Marshall.Authorization.Cedar.entity("ControlPlane", "marshall")
        ])
      end

    1 = Enum.count(allowed, & &1)
  end

  IO.puts(
    "Administrator bootstrap passed: three independent peers, three accounts, one administrator and one audit event."
  )
after
  Supervisor.stop(supervisor)
end
