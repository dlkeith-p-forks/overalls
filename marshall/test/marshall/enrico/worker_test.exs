defmodule Marshall.Enrico.WorkerTest do
  use Marshall.DataCase, async: false

  alias Marshall.Compute.Ledger
  alias Marshall.Enrico.{AuditEvent, Repository, Worker}

  @tls Path.expand("../../fixtures/tls", __DIR__)
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} = context do
    mode = Map.get(context, :mode, :resume)
    state = start_supervised!({Agent, fn -> %{mode: mode, polls: 0, posts: 0} end})
    Process.register(state, Marshall.Enrico.AttemptStub.State)

    server =
      start_supervised!(
        {Bandit,
         plug: {Marshall.Enrico.AttemptStub, Marshall.Enrico.AttemptStub.State},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@tls, "localhost.pem"),
         keyfile: Path.join(@tls, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    token_file = Path.join(dir, "token")
    File.write!(token_file, String.duplicate("a", 32))

    for {key, value} <- [
          enrico_url: "https://localhost:#{port}",
          enrico_token_file: token_file,
          enrico_ca_file: Path.join(@tls, "ca.pem")
        ] do
      previous = Application.get_env(:marshall, key)
      Application.put_env(:marshall, key, value)

      on_exit({key, :restore}, fn ->
        if previous == nil,
          do: Application.delete_env(:marshall, key),
          else: Application.put_env(:marshall, key, previous)
      end)
    end

    {:ok, state: state}
  end

  test "a failed job resumes its running attempt through a transient status outage", %{
    state: state
  } do
    attempt = Ash.UUID.generate()
    repository = repository()

    repository
    |> Ledger.update!(:begin_refresh, %{attempt_id: attempt, last_attempt_at: DateTime.utc_now()})
    |> Ledger.update!(:fail, %{next_refresh_at: DateTime.utc_now()})

    assert :ok = Worker.perform(%Oban.Job{args: %{"id" => repository.id}})
    assert [%{phase: :ready, head: head}] = Ledger.read!(Repository, id: repository.id)
    assert head == String.duplicate("a", 40)

    assert [%{kind: :refresh_succeeded, attempt_id: ^attempt}] =
             Ledger.read!(AuditEvent, repository_id: repository.id)

    assert %{polls: 3, posts: 0} = Agent.get(state, & &1)
  end

  @tag mode: :missing
  test "a lost attempt is audited before a new fetch starts", %{state: state} do
    old_attempt = Ash.UUID.generate()
    repository = repository()

    Ledger.update!(repository, :begin_refresh, %{
      attempt_id: old_attempt,
      last_attempt_at: DateTime.utc_now()
    })

    assert :ok = Worker.perform(%Oban.Job{args: %{"id" => repository.id}})

    assert [%{phase: :ready, head: head, attempt_id: new_attempt}] =
             Ledger.read!(Repository, id: repository.id)

    assert head == String.duplicate("a", 40)
    refute new_attempt == old_attempt
    assert %{polls: 2, posts: 1} = Agent.get(state, & &1)

    assert Enum.any?(Ledger.read!(AuditEvent, repository_id: repository.id), fn event ->
             event.kind == :refresh_failed and event.attempt_id == old_attempt and
               event.failure_reason == :service_unavailable
           end)
  end

  @spec repository() :: Repository.t()
  defp repository do
    Ledger.create!(Repository, :register, %{
      namespace: "github",
      owner: "nixos",
      name: "nixpkgs",
      registered_by_id: Ash.UUID.generate()
    })
  end
end
