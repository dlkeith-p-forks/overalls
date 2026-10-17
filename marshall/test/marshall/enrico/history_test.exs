defmodule Marshall.Enrico.HistoryTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Compute.Ledger
  alias Marshall.Enrico.{AuditEvent, Catalog, Repository, Worker}
  alias Marshall.EnricoHistoryService, as: Service
  @moduletag :tmp_dir
  @moduletag capture_log: true
  @tls Path.expand("../../fixtures/tls", __DIR__)

  setup %{tmp_dir: dir} do
    state = start_supervised!({Agent, fn -> %{next: "failed", attempts: %{}, requests: 0} end})

    server =
      start_supervised!(
        {Bandit,
         plug: {Service, state: state},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@tls, "localhost.pem"),
         keyfile: Path.join(@tls, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    token = Path.join(dir, "token")
    File.write!(token, String.duplicate("a", 32))

    for {key, value} <- [
          enrico_url: "https://localhost:#{port}",
          enrico_token_file: token,
          enrico_ca_file: Path.join(@tls, "ca.pem")
        ] do
      old = Application.get_env(:marshall, key)
      Application.put_env(:marshall, key, value)

      on_exit({:restore, key}, fn ->
        if old == nil,
          do: Application.delete_env(:marshall, key),
          else: Application.put_env(:marshall, key, old)
      end)
    end

    %{state: state}
  end

  # @cc [owner:ghuntley,label:verification] enrico-independent-public-histories
  # Generated histories MUST use public elevated catalog actions and actual
  # workers. An independently retained previous head and exact audit/job oracle
  # MUST check failures, ordinary-user refusal, removal and new registration;
  # synthetic HTTPS results MUST NOT be claimed as native Git acceptance.
  property "refresh failure and removal histories retain only published authority", %{
    state: state
  } do
    check all(
            histories <-
              list_of(list_of(boolean(), min_length: 1, max_length: 5),
                min_length: 1,
                max_length: 3
              ),
            max_runs: 18
          ) do
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      reader = Marshall.ComputeFixtures.user()
      name = "history-" <> Ash.UUID.generate()

      Enum.reduce(histories, [], fn outcomes, stale ->
        {:ok, repo} = Catalog.register(admin, "Fixture", name)
        assert repo.owner == "fixture"
        assert Catalog.get(reader, "FIXTURE", name).id == repo.id

        for old <- stale do
          before = Agent.get(state, & &1.requests)
          assert {:error, :not_found} = Catalog.inspect(reader, old, "tree", %{ref: old.head})
          assert Agent.get(state, & &1.requests) == before
        end

        assert queued?(repo.id, "refresh")

        assert events(repo.id) ==
                 Enum.sort([{:registered, admin.id, nil}, {:refresh_requested, admin.id, nil}])

        {_head, expected} =
          Enum.reduce(Enum.with_index(outcomes), {nil, events(repo.id)}, fn {success?, index},
                                                                            {previous, expected} ->
            before = inventory()
            assert {:error, :forbidden} = Catalog.refresh(reader, repo.id)
            assert {:error, :forbidden} = Catalog.remove(reader, repo.id)
            assert {:error, :forbidden} = Catalog.register(reader, "fixture", "other-" <> name)
            assert inventory() == before
            assert {:ok, _} = Catalog.refresh(admin, repo.id)
            expected = [{:refresh_requested, admin.id, nil} | expected]
            head = :crypto.hash(:sha, "#{repo.id}:#{index}") |> Base.encode16(case: :lower)
            status = if success?, do: %{state: "succeeded", head: head}, else: "failed"
            Agent.update(state, fn current -> %{current | next: status} end)

            assert Worker.perform(%Oban.Job{args: %{"id" => repo.id}}) ==
                     if(success?, do: :ok, else: {:error, :refresh_failed})

            [current] = Ledger.read!(Repository, id: repo.id)
            expected_head = if success?, do: head, else: previous
            assert current.head == expected_head
            assert current.phase == if(success?, do: :ready, else: :failed)
            kind = if success?, do: :refresh_succeeded, else: :refresh_failed
            expected = [{kind, nil, current.attempt_id} | expected]
            assert events(repo.id) == Enum.sort(expected)
            assert Catalog.get(reader, "fixture", name).head == expected_head
            {expected_head, expected}
          end)

        [published] = Ledger.read!(Repository, id: repo.id)
        assert :ok = Catalog.remove(admin, repo.id)
        assert queued?(repo.id, "remove")
        assert {:error, :removing} = Catalog.refresh(admin, repo.id)
        assert Catalog.get(reader, "fixture", name) == nil
        before = Agent.get(state, & &1.requests)

        assert {:error, :not_found} =
                 Catalog.inspect(reader, published, "blob", %{path: "README.md"})

        assert Agent.get(state, & &1.requests) == before
        assert :ok = Worker.perform(%Oban.Job{args: %{"id" => repo.id, "op" => "remove"}})
        assert Ledger.read!(Repository, id: repo.id) == []

        assert events(repo.id) ==
                 Enum.sort([{:remove_requested, admin.id, nil}, {:removed, nil, nil} | expected])

        [published | stale]
      end)
    end
  end

  @typep inventory :: %{
           repositories: [Repository.t()],
           events: [AuditEvent.t()],
           jobs: [[term()]]
         }
  @spec inventory() :: inventory()
  defp inventory do
    %{rows: jobs} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "SELECT id, args, state FROM oban_jobs WHERE worker=$1 ORDER BY id",
        ["Marshall.Enrico.Worker"],
        log: false
      )

    %{
      repositories: Ledger.read!(Repository) |> Enum.sort_by(& &1.id),
      events: Ledger.read!(AuditEvent) |> Enum.sort_by(& &1.id),
      jobs: jobs
    }
  end

  @spec events(String.t()) :: [{atom(), String.t() | nil, String.t() | nil}]
  defp events(id),
    do:
      Ledger.read!(AuditEvent, repository_id: id)
      |> Enum.map(&{&1.kind, &1.actor_id, &1.attempt_id})
      |> Enum.sort()

  @spec queued?(String.t(), String.t()) :: boolean()
  defp queued?(id, operation),
    do:
      Enum.any?(
        Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: Worker),
        &(&1.args == %{"id" => id, "op" => operation})
      )
end
