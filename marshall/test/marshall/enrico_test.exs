defmodule Marshall.EnricoTest do
  use Marshall.DataCase, async: false
  alias Marshall.Enrico.{Catalog, EnricoSource, Repository, AuditEvent}
  alias Marshall.Compute.Ledger

  test "public GitHub labels are the only accepted source names" do
    assert EnricoSource.valid?("NixOS", "nixpkgs")
    refute EnricoSource.valid?("-owner", "repo")
    refute EnricoSource.valid?("owner", "repo.git")
    refute EnricoSource.valid?("owner/another", "repo")
    refute EnricoSource.valid?("owner", "..")
  end

  test "an ordinary account cannot register, refresh or remove a mirror" do
    user = Marshall.ComputeFixtures.user()
    id = Ash.UUID.generate()
    assert {:error, :forbidden} = Catalog.register(user, "NixOS", "nixpkgs")
    assert {:error, :forbidden} = Catalog.refresh(user, id)
    assert {:error, :forbidden} = Catalog.remove(user, id)
    assert Ledger.read!(Repository) == []
  end

  test "failed refresh retains the last published head and append-only audit" do
    id = Ash.UUID.generate()

    repo =
      Ledger.create!(Repository, :register, %{
        namespace: "github",
        owner: "NixOS",
        name: "nixpkgs",
        registered_by_id: id
      })

    attempt = Ash.UUID.generate()

    started =
      Ledger.update!(repo, :begin_refresh, %{
        attempt_id: attempt,
        last_attempt_at: DateTime.utc_now()
      })

    ready =
      Ledger.update!(started, :publish, %{
        head: String.duplicate("a", 40),
        last_success_at: DateTime.utc_now()
      })

    retrying =
      Ledger.update!(ready, :begin_refresh, %{
        attempt_id: Ash.UUID.generate(),
        last_attempt_at: DateTime.utc_now()
      })

    failed = Ledger.update!(retrying, :fail, %{next_refresh_at: DateTime.utc_now()})
    assert failed.phase == :failed
    assert failed.head == String.duplicate("a", 40)

    event =
      Ledger.create!(AuditEvent, :record, %{
        repository_id: repo.id,
        attempt_id: attempt,
        kind: :refresh_failed,
        failure_reason: :tls_untrusted
      })

    assert event.actor_id == nil

    assert [%{kind: :refresh_failed, failure_reason: :tls_untrusted}] =
             Ledger.read!(AuditEvent, repository_id: repo.id)
  end

  test "removing a mirror revokes stale browser reads before cache deletion" do
    user = Marshall.ComputeFixtures.user()

    repo =
      Ledger.create!(Repository, :register, %{
        namespace: "github",
        owner: "nixos",
        name: "nixpkgs",
        registered_by_id: user.id
      })

    started =
      Ledger.update!(repo, :begin_refresh, %{
        attempt_id: Ash.UUID.generate(),
        last_attempt_at: DateTime.utc_now()
      })

    ready =
      Ledger.update!(started, :publish, %{
        head: String.duplicate("b", 40),
        last_success_at: DateTime.utc_now()
      })

    assert Catalog.get(user, "NixOS", "nixpkgs")
    removing = Ledger.update!(ready, :request_remove, %{})
    assert removing.phase == :removing
    assert Catalog.get(user, "NixOS", "nixpkgs") == nil
    assert {:error, :not_found} = Catalog.inspect(user, ready, "tree", %{ref: "HEAD"})
  end

  test "reconciler retries removal even when the next refresh is in the future" do
    user = Marshall.ComputeFixtures.user()

    repo =
      Ledger.create!(Repository, :register, %{
        namespace: "github",
        owner: "nixos",
        name: "nixpkgs",
        registered_by_id: user.id
      })

    ready =
      repo
      |> Ledger.update!(:begin_refresh, %{
        attempt_id: Ash.UUID.generate(),
        last_attempt_at: DateTime.utc_now()
      })
      |> Ledger.update!(:publish, %{
        head: String.duplicate("c", 40),
        next_refresh_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    Ledger.update!(ready, :request_remove, %{})
    assert :ok = Marshall.Enrico.Worker.perform(%Oban.Job{args: %{}})

    assert Enum.any?(
             Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: Marshall.Enrico.Worker),
             &(&1.args == %{"id" => repo.id, "op" => "remove"})
           )
  end
end
